defmodule ImagePipe.Response.ErrorStatus do
  @moduledoc false
  # Maps an internal processing failure reason to a client-facing
  # {http_status, message}. Status is keyed on a small closed class vocabulary
  # (the host-override seam); message is keyed on the full reason. classify/1
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
          | {:passthrough, integer()}

  # Classes a producer may assert as the lead atom of a reason. Deliberately
  # distinct from the core domain reason tags (:bad_status, :connect_error,
  # :decode, :input_limit, :unsupported_output_format, …) so a domain reason can
  # never be mistaken for a class lead.
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

  @plan_validation_error_tags [
    :unsupported_source,
    :invalid_output_plan,
    :invalid_expires,
    :invalid_cachebuster,
    :invalid_response_plan,
    :invalid_pipeline_plan,
    :invalid_pipeline_operation,
    :unprojectable_operation_for_cache_adapter,
    :detector_unavailable
  ]

  @spec resolve_status(term(), keyword()) :: {100..599, String.t()}
  def resolve_status(reason, _opts \\ []) do
    # _opts is the Option-A seam: a future host policy is consulted here before
    # the default table. Threaded now so adding it touches only this function.
    {default_status_code(classify(reason)), message_for(reason)}
  end

  # --- classification -------------------------------------------------------

  @spec classify(term()) :: class()
  def classify({:transform_error, inner}), do: class_lead(inner) || :unprocessable
  def classify({:render, inner}), do: classify(inner)
  def classify({:source, inner}), do: class_lead(inner) || source_domain_class(inner)
  def classify({:decode, _}), do: :unsupported_media
  def classify({:unsupported_source_format, _}), do: :unsupported_media
  def classify(:source_format_required), do: :unsupported_media
  def classify({:input_limit, _}), do: :payload_too_large
  def classify({:unsupported_output_format, _}), do: :unsupported_output
  def classify({:encode, _}), do: :server_error
  def classify({:encode, _, _}), do: :server_error
  def classify({:cache_write, _}), do: :server_error
  def classify({:config, _}), do: :server_error
  def classify(:empty_pipeline_plan), do: :unprocessable
  def classify({tag, _}) when tag in @plan_validation_error_tags, do: :unprocessable
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
  defp default_status_code({:passthrough, code}) when is_integer(code) and code in 100..599, do: code
  defp default_status_code({:passthrough, _code}), do: 502

  # --- message table (reason-keyed; specific, never embeds a URL) ------------

  @spec message_for(term()) :: String.t()
  def message_for({:transform_error, {:bad_request, :upscale_required}}),
    do: "upscaling requires the ^ prefix"

  def message_for({:transform_error, {:bad_request, _}}), do: "bad request"
  def message_for({:transform_error, _}), do: "invalid image transform"
  def message_for({:render, inner}), do: message_for(inner)
  def message_for({:source, {:bad_status, code}}), do: "upstream responded #{code}"
  def message_for({:source, :connect_error}), do: "source unreachable"
  def message_for({:source, :too_many_redirects}), do: "too many redirects"
  def message_for({:source, :redirect_not_followed}), do: "redirect not followed"
  def message_for({:source, :invalid_redirect}), do: "invalid redirect"
  def message_for({:source, :receive_timeout}), do: "source timeout"
  def message_for({:source, :body_too_large}), do: "source response exceeds the size limit"

  def message_for({:source, reason})
      when reason in [:invalid_body, :invalid_stream_chunk, :stream_exception],
      do: "incomplete source response"

  def message_for({:source, reason})
      when reason in [:invalid_adapter_result, :invalid_adapter_config, :missing_adapter],
      do: "configuration error"

  def message_for({:decode, _}), do: "source response is not a supported image"
  def message_for({:unsupported_source_format, _}), do: "source response is not a supported image"
  def message_for(:source_format_required), do: "source response is not a supported image"
  def message_for({:input_limit, _}), do: "source image is too large"

  def message_for({:unsupported_output_format, _}),
    do: "requested output format is not supported by this server"

  def message_for({:cache_write, _}), do: "cache error"
  def message_for({:config, _}), do: "configuration error"
  def message_for({:encode, _}), do: "error encoding image"
  def message_for({:encode, _, _}), do: "error encoding image"
  def message_for(reason), do: class_default_message(classify(reason))

  defp class_default_message(:bad_request), do: "bad request"
  defp class_default_message(:unprocessable), do: "unprocessable image request"
  defp class_default_message(:not_found), do: "source not found"
  defp class_default_message(:bad_gateway), do: "bad gateway"
  defp class_default_message(:gateway_timeout), do: "source timeout"
  defp class_default_message(:payload_too_large), do: "source image is too large"
  defp class_default_message(:unsupported_media), do: "source response is not a supported image"

  defp class_default_message(:unsupported_output),
    do: "requested output format is not supported by this server"

  defp class_default_message(:server_error), do: "internal server error"
  defp class_default_message({:passthrough, _}), do: "upstream error"
end
