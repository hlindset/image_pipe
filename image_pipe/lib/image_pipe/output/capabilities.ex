defmodule ImagePipe.Output.Capabilities do
  @moduledoc false

  # libvips output-format write capability, probed once and cached in
  # :persistent_term. Capabilities cannot change without a process restart, so a
  # process-lifetime cache is correct here.

  require Logger

  @probed_formats [:avif, :webp]
  @baseline_formats [:jpeg, :png]

  @spec probe() :: :ok
  def probe do
    Enum.each(@probed_formats, fn format ->
      supported? = probe_once(format)
      maybe_warn(format, supported?)
    end)

    :ok
  end

  @spec supports?(atom()) :: boolean()
  def supports?(format) when format in @baseline_formats, do: true
  def supports?(format) when format in @probed_formats, do: probe_once(format)
  def supports?(_format), do: false

  @doc "The output formats this libvips build can write."
  @spec writable() :: [atom()]
  def writable, do: @baseline_formats ++ Enum.filter(@probed_formats, &probe_once/1)

  @spec maybe_warn(atom(), boolean()) :: :ok
  defp maybe_warn(_format, true), do: :ok

  defp maybe_warn(format, false) do
    Logger.warning(
      "ImagePipe: libvips build cannot write #{format}; requests resolving to " <>
        "#{format} will fall back (automatic) or be rejected (explicit)."
    )

    :ok
  end

  # Reads the cached result; probes once on first miss and caches it. The probe
  # is a 1x1 in-memory encode, so first-call cost is negligible.
  # Concurrent first-callers may both probe and put; benign — the result is
  # deterministic and :persistent_term.put/2 is atomic.
  defp probe_once(format) do
    case :persistent_term.get({__MODULE__, format}, :unknown) do
      :unknown ->
        result = probe_format(format)
        :persistent_term.put({__MODULE__, format}, result)
        result

      result ->
        result
    end
  end

  defp probe_format(format) do
    with {:ok, image} <- Image.new(1, 1),
         {:ok, _binary} <- Image.write(image, :memory, suffix: suffix(format)) do
      true
    else
      _error -> false
    end
  rescue
    # External libvips boundary: any failure means the encoder is unavailable.
    _exception -> false
  end

  defp suffix(:avif), do: ".avif"
  defp suffix(:webp), do: ".webp"
end
