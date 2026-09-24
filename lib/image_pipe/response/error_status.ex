defmodule ImagePipe.Response.ErrorStatus do
  @moduledoc false
  # Maps an internal processing failure reason to a client-facing
  # {http_status, message}. Status is keyed on a small closed class vocabulary;
  # message is keyed on the full reason. classify/1
  # resolves a class-leading reason first ({<known_class>, _detail}), then the
  # core domain table, then a total fallback. See
  # docs/superpowers/specs/2026-06-29-error-status-mapping-design.md.

  @type class ::
          :bad_request
          | :unprocessable
          | :not_found
          | :bad_gateway
          | :gateway_timeout
          | :payload_too_large
          | :unsupported_media
          | :unsupported_output
          | :server_error
          | :unavailable
          | {:passthrough, integer()}

  # Classes a producer may assert as the lead atom of a reason. Deliberately
  # distinct from the core domain reason tags (:bad_status, :connect_error,
  # :decode, :input_limit, :unsupported_output_format, …) so a domain reason can
  # never be mistaken for a class lead. Only the tuple form `{class, detail}`
  # routes by class (see class_lead/1); a *bare* class atom (e.g. a source
  # adapter returning `{:source, :not_found}`) is treated as a domain reason and
  # falls through to the domain table / neutral fallback, not auto-routed.
  @leading_classes [
    :bad_request,
    :not_found,
    :bad_gateway,
    :gateway_timeout,
    :payload_too_large,
    :unsupported_media,
    :unsupported_output,
    :server_error
  ]

  @spec resolve_status(term()) :: {100..599, String.t()}
  def resolve_status(reason) do
    {default_status_code(classify(reason)), message_for(reason)}
  end

  # --- classification -------------------------------------------------------

  @spec classify(term()) :: class()
  def classify({:transform, inner}), do: class_lead(inner) || :unprocessable
  def classify({:source, inner}), do: class_lead(inner) || source_domain_class(inner)
  def classify({:decode, _}), do: :unsupported_media
  def classify(:source_format_required), do: :unsupported_media
  def classify({:input_limit, _}), do: :payload_too_large
  def classify({:unsupported_output_format, _}), do: :unsupported_output
  def classify({:encode, _}), do: :server_error
  def classify({:encode, _, _}), do: :server_error
  def classify({:detector, :unavailable}), do: :unprocessable
  def classify({:processing, :timeout}), do: :gateway_timeout

  def classify({:processing, reason}) when reason in [:overloaded, :queue_timeout, :unavailable],
    do: :unavailable

  def classify(_other), do: :server_error

  # Step 1: a reason that leads with a known class atom routes by that class.
  # Passthrough accepts any integer; the status table clamps to a valid range.
  defp class_lead({:passthrough, code}) when is_integer(code), do: {:passthrough, code}
  defp class_lead({class, _detail}) when class in @leading_classes, do: class
  defp class_lead(_), do: nil

  # Step 2: core source domain reasons. Step 3 (fallback) is the last clause.
  defp source_domain_class(:connect_error), do: :not_found
  defp source_domain_class(:too_many_redirects), do: :not_found
  defp source_domain_class(:redirect_not_followed), do: :not_found
  defp source_domain_class(:invalid_redirect), do: :not_found
  defp source_domain_class(:receive_timeout), do: :gateway_timeout

  defp source_domain_class(reason)
       when reason in [:unexpected_not_modified, :invalid_not_modified],
       do: :bad_gateway

  defp source_domain_class(reason)
       when reason in [:truncated_body, :connection_reset, :connection_closed, :transport_error],
       do: :bad_gateway

  defp source_domain_class(:body_too_large), do: :unprocessable
  defp source_domain_class(:invalid_body), do: :unprocessable
  defp source_domain_class(:invalid_stream_chunk), do: :unprocessable
  defp source_domain_class(:stream_exception), do: :unprocessable
  defp source_domain_class(:invalid_adapter_result), do: :server_error
  defp source_domain_class(:invalid_adapter_config), do: :server_error
  defp source_domain_class(:missing_adapter), do: :server_error
  defp source_domain_class({:bad_status, code}) when code in 400..499, do: {:passthrough, code}
  defp source_domain_class({:bad_status, code}) when code in 500..599, do: :bad_gateway
  defp source_domain_class({:bad_status, _code}), do: :not_found
  defp source_domain_class(_other), do: :unprocessable

  # --- status table ---------------------------------------------------------

  @spec default_status_code(class()) :: 100..599
  defp default_status_code(:bad_request), do: 400
  defp default_status_code(:unprocessable), do: 422
  defp default_status_code(:not_found), do: 404
  defp default_status_code(:bad_gateway), do: 502
  defp default_status_code(:gateway_timeout), do: 504
  defp default_status_code(:payload_too_large), do: 413
  defp default_status_code(:unsupported_media), do: 415
  defp default_status_code(:unsupported_output), do: 501
  defp default_status_code(:server_error), do: 500
  defp default_status_code(:unavailable), do: 503

  defp default_status_code({:passthrough, code}) when is_integer(code) and code in 100..599,
    do: code

  defp default_status_code({:passthrough, _code}), do: 502

  # --- message table (reason-keyed; specific, never embeds a URL) ------------

  @spec message_for(term()) :: String.t()
  def message_for({:transform, {:bad_request, :region_out_of_bounds}}),
    do: "requested region is outside the image"

  def message_for({:transform, {:bad_request, _}}), do: "bad request"
  def message_for({:transform, _}), do: "invalid image transform"
  def message_for({:source, {:bad_status, code}}), do: "upstream responded #{code}"
  def message_for({:source, :connect_error}), do: "source unreachable"
  def message_for({:source, :too_many_redirects}), do: "too many redirects"
  def message_for({:source, :redirect_not_followed}), do: "redirect not followed"
  def message_for({:source, :invalid_redirect}), do: "invalid redirect"
  def message_for({:source, :receive_timeout}), do: "source timeout"

  def message_for({:source, reason})
      when reason in [:unexpected_not_modified, :invalid_not_modified],
      do: "invalid source validation response"

  def message_for({:source, :truncated_body}), do: "source response incomplete"

  def message_for({:source, reason})
      when reason in [:connection_reset, :connection_closed, :transport_error],
      do: "source connection interrupted"

  def message_for({:source, :body_too_large}), do: "source response exceeds the size limit"

  def message_for({:source, reason})
      when reason in [:invalid_body, :invalid_stream_chunk, :stream_exception],
      do: "incomplete source response"

  def message_for({:source, reason})
      when reason in [:invalid_adapter_result, :invalid_adapter_config, :missing_adapter],
      do: "configuration error"

  # Generic fallback for an unrecognized source reason (a host-adapter reason we
  # don't have specific copy for) — keeps the "source" context.
  def message_for({:source, _}), do: "invalid image source"

  def message_for({:decode, _}), do: "source response is not a supported image"
  def message_for(:source_format_required), do: "source response is not a supported image"
  def message_for({:input_limit, _}), do: "source image is too large"

  def message_for({:unsupported_output_format, _}),
    do: "requested output format is not supported by this server"

  def message_for({:encode, _}), do: "error encoding image"
  def message_for({:encode, _, _}), do: "error encoding image"

  def message_for({:detector, :unavailable}), do: "invalid image transform"
  def message_for({:processing, :timeout}), do: "image processing timeout"
  def message_for({:processing, :queue_timeout}), do: "image processing queue timeout"
  def message_for({:processing, :overloaded}), do: "image processing overloaded"
  def message_for({:processing, :unavailable}), do: "image processing unavailable"

  # Any reason not matched above is an unrecognized/unknown failure, which
  # classify/1 maps to :server_error (500).
  def message_for(_reason), do: "internal server error"
end
