defmodule ImagePipe.Telemetry.RequestContext do
  @moduledoc false
  # What a request carries across ImagePipe's process hops: its OpenTelemetry
  # context and the caller's Logger metadata, so spans nest under the request
  # and log lines and telemetry handlers keep the host's metadata (such as
  # `Plug.RequestId`'s `:request_id`) in every process that serves it.
  #
  # The context is carried whenever the OpenTelemetry API is compiled in,
  # tracer attached or not, so the host's own instrumentation nests too.

  @compile {:no_warn_undefined, [:otel_ctx]}

  @type t :: {map() | nil, keyword()}

  @spec capture() :: t()
  def capture, do: {current(), Logger.metadata()}

  # Seeds a process that serves only this request.
  @spec adopt(t()) :: :ok
  def adopt({context, metadata}) do
    Logger.metadata(metadata)
    put(context)
  end

  # Runs `fun` with the request's context in a process shared by many
  # requests, restoring that process's own context and metadata after.
  @spec within(t(), (-> result)) :: result when result: term()
  def within({context, metadata}, fun) do
    own = capture()
    adopt({context, metadata})

    try do
      fun.()
    after
      {own_context, own_metadata} = own
      put(own_context)
      Logger.reset_metadata(own_metadata)
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
