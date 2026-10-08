defmodule ImagePipe.API.URL do
  @moduledoc false

  alias ImagePipe.API.{Path, Serializer}
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Source, as: PlanSource
  alias ImagePipe.Plan.Spec.Issue
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
    with {:ok, source} <- source(source),
         :ok <- validate_plan(plan, config),
         {:ok, plan} <- conceal_watermarks(plan, config, options, config[:encrypt_source]),
         {:ok, segments} <- segments(plan),
         {:ok, source_segments} <-
           source_segments(source, config, options, config[:encrypt_source]) do
      path = "/" <> Enum.join(segments ++ source_segments, "/")
      {:ok, config[:base_url] <> sign(path, config)}
    end
  end

  # Writes the URL the plan asks for whatever its issues, and returns them
  # with the errors first. Only malformed `options` raise.
  def build_with_issues(plan, source, config, options) do
    issues =
      case check(plan, config) do
        {:ok, warnings} -> warnings
        {:error, issues} -> issues
      end

    encrypt? = config[:encrypt_source]

    case source_segments("options", config, options, encrypt?) do
      {:ok, _segments} -> :ok
      {:error, reason} -> raise ArgumentError, "invalid URL options: #{reason}"
    end

    {source_segments, source_issues} = written_source(source, config, options, encrypt?)
    segments = plan |> written_plan(config, options, encrypt?) |> Serializer.segments()

    count_issues =
      case length(segments) <= Path.max_option_segments() do
        true -> []
        false -> [issue(:too_many_options)]
      end

    path = "/" <> Enum.join(segments ++ source_segments, "/")
    {errors, warnings} = Enum.split_with(issues, &(&1.severity == :error))
    {config[:base_url] <> sign(path, config), errors ++ source_issues ++ count_issues ++ warnings}
  end

  # Under `encrypt_source`, no source is written in plain text: an invalid
  # source, or a rejected watermark source, is left empty.
  defp written_source(source, config, options, encrypt?) do
    case source(source) do
      {:ok, source} ->
        {:ok, segments} = source_segments(source, config, options, encrypt?)
        {segments, []}

      {:error, :invalid_source} ->
        text = if is_binary(source) and not encrypt?, do: source, else: ""
        {["src", URI.encode(text, &URI.char_unreserved?/1)], [issue(:invalid_source)]}
    end
  end

  defp written_plan(plan, _config, _options, false), do: plan

  defp written_plan(plan, config, options, true) do
    case conceal_watermarks(plan, config, options, true) do
      {:ok, plan} -> Plan.blank_rejected(plan, :watermark_source)
      {:error, reason} -> raise ArgumentError, "invalid URL options: #{reason}"
    end
  end

  defp issue(reason), do: %Issue{reason: reason, locations: [], detail: nil}

  defp source(source) when is_binary(source) and source != "" do
    source = PlanSource.normalize(source)

    case source != "" and String.valid?(source) do
      true -> {:ok, source}
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

  defp source_segments(_source, _config, [iv: iv], false)
       when iv in [:deterministic, :random] or (is_binary(iv) and byte_size(iv) == 16),
       do: {:error, :source_encryption_disabled}

  defp source_segments(_source, _config, _options, false),
    do: {:error, :invalid_encryption_options}

  # Browsers normalize dot path segments even when the dots are percent-encoded.
  defp source_segments(source) when source in [".", ".."],
    do: ["src64", Base.url_encode64(source, padding: false)]

  defp source_segments(source), do: ["src", URI.encode(source, &URI.char_unreserved?/1)]

  # Watermark sources follow the main source: concealed whenever it is.
  defp conceal_watermarks(plan, config, options, true),
    do: Plan.map_groups(plan, &conceal_watermark(&1, config, options))

  defp conceal_watermarks(plan, _config, _options, _encrypt?), do: {:ok, plan}

  defp conceal_watermark(%{watermark_source: source} = group, config, options) do
    with {:ok, token} <- encrypt_watermark(source, config, Keyword.get(options, :iv)) do
      {:ok, group |> Map.delete(:watermark_source) |> Map.put(:watermark_token, token)}
    end
  end

  defp conceal_watermark(group, _config, _options), do: {:ok, group}

  # The main source consumes an explicit IV; each watermark source derives its
  # own from it so no IV encrypts two different sources.
  defp encrypt_watermark(source, config, iv) when is_binary(iv),
    do: Security.encrypt_salted_source(source, config, iv)

  defp encrypt_watermark(source, config, mode) do
    options = if mode, do: [iv: mode], else: []
    Security.encrypt_source(source, config, options)
  end

  defp validate_plan(plan, config) do
    case check(plan, config) do
      {:ok, _warnings} -> :ok
      {:error, issues} -> {:error, {:invalid_request, issues}}
    end
  end

  # Semantic checks run only when the builder knows the server's presets.
  # Under a lookup, a name the known map lacks defers to the server, and only
  # groups without such a name are checked. Watermark names, and whether the
  # server takes request watermark sources, are each checked when known.
  @doc false
  @spec check(Plan.t(), keyword()) ::
          {:ok, [ImagePipe.Plan.Spec.Issue.t()]} | {:error, [ImagePipe.Plan.Spec.Issue.t()]}
  def check(plan, config) do
    case config[:validate_against] do
      nil ->
        Plan.built(plan)

      %{presets: presets, request_defaults: defaults, lookup?: lookup?} = known ->
        watermarks = watermarks(known.watermarks, known.request_watermarks)

        if lookup?,
          do: Plan.validate_known(plan, presets, defaults, watermarks),
          else: Plan.validate(plan, presets, defaults, watermarks)
    end
  end

  defp watermarks(nil, nil), do: nil

  defp watermarks(names, request_sources?),
    do: %{names: names, request_sources?: request_sources? != false}

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
