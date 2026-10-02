defmodule ImagePipe.Response.ErrorStatus do
  @moduledoc false
  # Maps an internal processing failure reason to a client-facing
  # {http_status, message}. Status is keyed on a small closed class vocabulary;
  # message is keyed on the full reason. classify/1 resolves a class-leading
  # reason first ({<known_class>, _detail}), then the core domain table, then a
  # total fallback. docs/errors.md documents the resulting contract.

  @type class ::
          :bad_request
          | :unprocessable
          | :not_found
          | :bad_gateway
          | :gateway_timeout
          | :payload_too_large
          | :unsupported_media
          | :not_implemented
          | :server_error
          | :unavailable

  # Classes a producer may assert as the lead atom of a reason. Deliberately
  # distinct from the core domain reason tags (:bad_status, :connect_error,
  # :decode, :input_limit, :unsupported_output_format, …) so a domain reason can
  # never be mistaken for a class lead. Only the tuple form `{class, detail}`
  # routes by class (see class_lead/1); a *bare* atom is a domain reason and
  # goes through the domain table.
  @leading_classes [
    :bad_request,
    :not_found,
    :bad_gateway,
    :gateway_timeout,
    :payload_too_large,
    :unsupported_media,
    :not_implemented,
    :server_error
  ]

  # Origin statuses that mean "no such source" to the client. 401/403 are
  # concealed as absence: the client can't fix ImagePipe's access to the origin,
  # and S3 answers 403 for a missing key without ListBucket.
  @absent_statuses [401, 403, 404, 410]

  # Source reasons that mean "no such source" to the client: nothing at that
  # path, or a path, host, address, or scheme the mount's policy won't serve.
  # Denials are concealed as absence so the policy can't be probed.
  @absent_reasons [
    :not_found,
    :invalid_object,
    :denied_path,
    :denied_bucket,
    :denied_host,
    :denied_scheme,
    :denied_address
  ]

  @spec resolve_status(term()) :: {100..599, String.t()}
  def resolve_status(reason) do
    {status_code(classify(reason)), message_for(reason)}
  end

  # --- classification -------------------------------------------------------

  @spec classify(term()) :: class()
  def classify({:transform, inner}), do: class_lead(inner) || :unprocessable
  def classify({:source, inner}), do: class_lead(inner) || source_domain_class(inner)
  def classify({:decode, {:peek_failed, _posix}}), do: :server_error
  def classify({:decode, _}), do: :unsupported_media
  def classify(:source_format_required), do: :unsupported_media
  def classify({:input_limit, _}), do: :payload_too_large
  def classify({:page_out_of_range, _page, _pages}), do: :unprocessable
  def classify({:unsupported_output_format, _}), do: :not_implemented
  def classify({:encode, _}), do: :server_error
  def classify({:encode, _, _}), do: :server_error
  def classify({:detector, :unavailable}), do: :not_implemented
  def classify({:detector, :not_ready}), do: :unavailable
  def classify({:detector, {:unknown_classes, _names}}), do: :bad_request

  def classify({:processing, reason})
      when reason in [:timeout, :overloaded, :queue_timeout, :unavailable],
      do: :unavailable

  def classify({:session, :timeout}), do: :unavailable
  def classify({:preset, :lookup_unavailable}), do: :unavailable

  def classify(_other), do: :server_error

  # Step 1: a reason that leads with a known class atom routes by that class.
  defp class_lead({class, _detail}) when class in @leading_classes, do: class
  defp class_lead(_), do: nil

  # Step 2: core source domain reasons. Step 3 (fallback) is the last clause.
  defp source_domain_class(reason) when reason in @absent_reasons, do: :not_found

  defp source_domain_class({:bad_status, code}) when code in @absent_statuses, do: :not_found
  defp source_domain_class({:bad_status, _code}), do: :bad_gateway
  defp source_domain_class(:receive_timeout), do: :gateway_timeout
  defp source_domain_class(:body_too_large), do: :payload_too_large

  defp source_domain_class(reason)
       when reason in [
              :unreadable,
              :credentials_unavailable,
              :invalid_adapter_result,
              :invalid_adapter_config,
              :missing_adapter
            ],
       do: :server_error

  # Transport failures, broken origin responses, and any source reason a host
  # adapter returns without a class lead: the origin failed, not the request.
  defp source_domain_class(_other), do: :bad_gateway

  # --- status table ---------------------------------------------------------

  @spec status_code(class()) :: 100..599
  defp status_code(:bad_request), do: 400
  defp status_code(:not_found), do: 404
  defp status_code(:payload_too_large), do: 413
  defp status_code(:unsupported_media), do: 415
  defp status_code(:unprocessable), do: 422
  defp status_code(:server_error), do: 500
  defp status_code(:not_implemented), do: 501
  defp status_code(:bad_gateway), do: 502
  defp status_code(:unavailable), do: 503
  defp status_code(:gateway_timeout), do: 504

  # --- message table (reason-keyed; specific, never embeds a URL) ------------

  @spec message_for(term()) :: String.t()
  def message_for({:transform, {:bad_request, :region_out_of_bounds}}),
    do: "requested region is outside the image"

  def message_for({:transform, {:bad_request, _}}), do: "bad request"
  def message_for({:transform, {:server_error, {:detector, _}}}), do: "object detection failed"
  def message_for({:transform, _}), do: "invalid image transform"

  def message_for({:source, reason}) when reason in @absent_reasons, do: "source not found"

  def message_for({:source, {:bad_status, code}}) when code in @absent_statuses,
    do: "source not found"

  def message_for({:source, {:bad_status, _code}}), do: "source responded with an error"
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

  def message_for({:source, reason}) when reason in [:unreadable, :credentials_unavailable],
    do: "source unavailable"

  # Generic fallback for an unrecognized source reason (a host-adapter reason we
  # don't have specific copy for) — keeps the "source" context.
  def message_for({:source, _}), do: "source error"

  def message_for({:decode, {:peek_failed, _posix}}), do: "source unavailable"
  def message_for({:decode, _}), do: "source response is not a supported image"
  def message_for(:source_format_required), do: "source response is not a supported image"
  def message_for({:input_limit, _}), do: "source image is too large"

  def message_for({:page_out_of_range, _page, _pages}),
    do: "requested page does not exist in the source image"

  def message_for({:unsupported_output_format, _}),
    do: "requested output format is not supported by this server"

  def message_for({:encode, _}), do: "error encoding image"
  def message_for({:encode, _, _}), do: "error encoding image"

  def message_for({:detector, :unavailable}),
    do: "object detection is not available on this server"

  def message_for({:detector, :not_ready}),
    do: "object detection models are not loaded yet"

  def message_for({:detector, {:unknown_classes, names}}),
    do: "unknown detection class: " <> Enum.join(names, ", ")

  def message_for({:processing, :timeout}), do: "image processing timeout"
  def message_for({:session, :timeout}), do: "image processing timeout"
  def message_for({:processing, :queue_timeout}), do: "image processing queue timeout"
  def message_for({:processing, :overloaded}), do: "image processing overloaded"
  def message_for({:processing, :unavailable}), do: "image processing unavailable"
  def message_for({:preset, :lookup_unavailable}), do: "preset lookup unavailable"
  def message_for({:preset, :invalid_definition}), do: "configuration error"

  # Any reason not matched above is an unrecognized/unknown failure, which
  # classify/1 maps to :server_error (500).
  def message_for(_reason), do: "internal server error"
end
