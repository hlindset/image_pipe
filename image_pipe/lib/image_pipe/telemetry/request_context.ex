defmodule ImagePipe.Telemetry.RequestContext do
  @moduledoc false
  # What a request carries across ImagePipe's process hops: its OpenTelemetry
  # context, the caller's Logger metadata, and the alias its summary fields go
  # to, so spans nest under the request, log lines and telemetry handlers keep
  # the host's metadata (such as `Plug.RequestId`'s `:request_id`) in every
  # process that serves it, and the summary hears from all of them.
  #
  # The context is carried whenever the OpenTelemetry API is compiled in,
  # tracer attached or not, so the host's own instrumentation nests too.

  @compile {:no_warn_undefined, [:otel_ctx]}

  alias ImagePipe.Telemetry.Summary

  @type t :: {map() | nil, keyword(), Summary.handle()}

  @spec capture() :: t()
  def capture, do: {current(), Logger.metadata(), Summary.current()}

  # Seeds a process that serves only this request.
  @spec adopt(t()) :: :ok
  def adopt({context, metadata, summary}) do
    Logger.metadata(metadata)
    Summary.adopt(summary)
    put(context)
  end

  # Runs `fun` with the request's context in a process shared by many
  # requests, restoring that process's own context and metadata after.
  @spec within(t(), (-> result)) :: result when result: term()
  def within(request, fun) do
    own = capture()
    adopt(request)

    try do
      fun.()
    after
      {own_context, own_metadata, own_summary} = own
      put(own_context)
      Logger.reset_metadata(own_metadata)
      Summary.adopt(own_summary)
    end
  end

  if Code.ensure_loaded?(:otel_ctx) do
    defp current, do: :otel_ctx.get_current()

    defp put(context) do
      _ = :otel_ctx.attach(context)
      :ok
    end
  else
    defp current, do: nil
    defp put(nil), do: :ok
  end
end
