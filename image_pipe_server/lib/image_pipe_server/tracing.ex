defmodule ImagePipeServer.Tracing do
  @moduledoc """
  Decides from the standard `OTEL_*` variables whether the server exports
  traces.

  Tracing is off unless an OTLP endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT` or
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) or an exporter (`OTEL_TRACES_EXPORTER`
  other than `none`) is set, and `OTEL_SDK_DISABLED` isn't `true`. The
  OpenTelemetry SDK reads the other variables itself, such as
  `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_HEADERS`, and `OTEL_TRACES_SAMPLER`.

  `config/runtime.exs` applies `sdk` to the SDK before it starts; the
  application attaches ImagePipe's tracer when `enabled?`.
  """

  @endpoints ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"]

  @spec settings(%{String.t() => String.t()}) :: %{enabled?: boolean(), sdk: keyword()}
  def settings(env) do
    exporter = Map.get(env, "OTEL_TRACES_EXPORTER")
    endpoint? = Enum.any?(@endpoints, &Map.has_key?(env, &1))

    cond do
      String.downcase(Map.get(env, "OTEL_SDK_DISABLED", "")) == "true" -> off()
      exporter == "none" -> off()
      exporter != nil -> %{enabled?: true, sdk: []}
      endpoint? -> %{enabled?: true, sdk: [traces_exporter: :otlp]}
      true -> off()
    end
  end

  defp off, do: %{enabled?: false, sdk: []}
end
