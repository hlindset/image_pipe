defmodule ImagePipe.API.URL do
  @moduledoc false

  alias ImagePipe.API.{Path, Serializer}
  alias ImagePipe.Plan
  alias ImagePipe.Security

  def sign_path("/" <> _ = path, config) do
    if String.starts_with?(path, "/sig=") or String.contains?(path, ["?", "#"]) do
      raise ArgumentError, "expected an unsigned mount-relative path without query or fragment"
    end

    case Security.sign(path, config) do
      nil -> raise ArgumentError, "sign_path requires signing keys"
      signature -> "/sig=" <> signature <> path
    end
  end

  def sign_path(_path, _config),
    do: raise(ArgumentError, "expected a mount-relative path starting with /")

  def build(plan, source, config, options) do
    with :ok <- source(source),
         :ok <- validate_plan(plan, config),
         {:ok, segments} <- segments(plan),
         {:ok, source_segments} <-
           source_segments(source, config, options, config[:encrypt_source]) do
      path = "/" <> Enum.join(segments ++ source_segments, "/")
      {:ok, config[:base_url] <> sign(path, config)}
    end
  end

  defp source(source) when is_binary(source) and source != "" do
    case String.valid?(source) do
      true -> :ok
      false -> {:error, :invalid_source}
    end
  end

  defp source(_source), do: {:error, :invalid_source}

  defp source_segments(source, config, options, true) do
    with {:ok, token} <- Security.encrypt_source(source, config, options) do
      {:ok, ["enc", token]}
    end
  end

  defp source_segments(source, _config, [], false),
    do: {:ok, source_segments(source)}

  defp source_segments(_source, _config, _options, false),
    do: {:error, :source_encryption_disabled}

  # Browsers normalize dot path segments even when the dots are percent-encoded.
  defp source_segments(source) when source in [".", ".."],
    do: ["src64", Base.url_encode64(source, padding: false)]

  defp source_segments(source), do: ["src", URI.encode(source, &URI.char_unreserved?/1)]

  defp validate_plan(plan, config) do
    presets = config[:presets]
    names = Map.get(plan.options, :presets, [])

    inherited? = names != [] or Map.has_key?(presets, "default")

    cond do
      inherited? and Serializer.empty_overrides?(plan) ->
        {:error, :unrepresentable_preset_override}

      Enum.all?(names, &Map.has_key?(presets, &1)) ->
        validate_known_plan(plan, presets)

      true ->
        :ok
    end
  end

  defp validate_known_plan(plan, presets) do
    case Plan.validate(plan, presets) do
      :ok -> :ok
      {:error, issues} -> {:error, {:invalid_request, issues}}
    end
  end

  defp segments(plan) do
    segments = Serializer.segments(plan)

    case length(segments) <= Path.max_option_segments() do
      true -> {:ok, segments}
      false -> {:error, :too_many_options}
    end
  end

  defp sign(path, config) do
    case Security.sign(path, config) do
      nil -> path
      signature -> "/sig=" <> signature <> path
    end
  end
end
