defmodule ImagePipe.Source.File do
  @moduledoc """
  Built-in adapter for files below a configured root directory.

  Configure it with `:root` and a stable, public `:root_id`. The optional
  `:stable`, `:internal_cache`, and `:http_cache` settings control whether the
  source can participate in internal and generated HTTP caching.
  """

  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  @options_schema NimbleOptions.new!(
                    root: [type: :string, required: true],
                    root_id: [type: :string, required: true],
                    stable: [type: {:in, [:auto, :trusted]}, default: :auto],
                    internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
                    http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit]
                  )

  @impl Source
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} ->
        validated =
          validated
          |> Keyword.update!(:root, &Path.expand/1)
          |> Keyword.put(:telemetry_kind, :file)

        {:ok, validated}

      {:error, error} ->
        {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @impl Source
  def resolve(%SourcePath{segments: segments}, opts, _runtime_opts) do
    with :ok <- validate_segments(segments),
         {:ok, path} <- safe_path(opts, segments) do
      identity = [
        kind: :path,
        adapter: :path,
        root: Keyword.fetch!(opts, :root_id),
        path: segments
      ]

      stable? = Keyword.fetch!(opts, :stable) == :trusted

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: identity,
         internal_cache: internal_cache_mode(opts, stable?),
         http_cache: Keyword.fetch!(opts, :http_cache),
         cache_semantics: cache_semantics(opts, stable?, identity),
         fetch: [path: path, root: Keyword.fetch!(opts, :root), segments: segments]
       }}
    end
  end

  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, _runtime_opts) do
    with {:ok, path} <- safe_path(fetch[:root], fetch[:segments]),
         :ok <- regular_file(path) do
      {:ok, %Response{path: path}}
    end
  end

  defp validate_segments(segments) when is_list(segments) do
    if Enum.all?(segments, &valid_segment?/1) do
      :ok
    else
      {:error, {:source, :denied_path}}
    end
  end

  defp validate_segments(_segments), do: {:error, {:source, :denied_path}}

  defp valid_segment?(segment) when is_binary(segment) do
    segment != "" and segment != "." and segment != ".." and
      not String.contains?(segment, ["/", "\\"])
  end

  defp valid_segment?(_segment), do: false

  defp safe_path(opts, segments) when is_list(opts) do
    safe_path(Keyword.fetch!(opts, :root), segments)
  end

  defp safe_path(root, segments) do
    relative = Path.join(segments)

    case Path.safe_relative(relative, root) do
      {:ok, safe_relative} -> {:ok, Path.join(root, safe_relative)}
      :error -> {:error, {:source, :denied_path}}
    end
  end

  defp regular_file(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, {:source, :unreadable}}
      {:error, :enoent} -> {:error, {:source, :not_found}}
      {:error, :eacces} -> {:error, {:source, :unreadable}}
      {:error, _reason} -> {:error, {:source, :unreadable}}
    end
  end

  defp internal_cache_mode(opts, stable?) do
    case Keyword.fetch!(opts, :internal_cache) do
      :enabled -> :enabled
      :disabled -> :disabled
      :auto -> if stable?, do: :enabled, else: :disabled
    end
  end

  defp cache_semantics(_opts, stable?, identity) do
    byte_identity =
      if stable? do
        {:strong, identity}
      else
        :none
      end

    %CacheSemantics{byte_identity: byte_identity, stable?: stable?}
  end
end
