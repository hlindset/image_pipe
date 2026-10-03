defmodule ImagePipe.Cache.FileSystem do
  @moduledoc """
  Cache adapter that stores processed images, or originals, as files on local disk.

      cache: {ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/processed"}

  Without `:max_size_bytes` the cache grows without limit. With it, the cache
  runs in bounded mode, with `:max_size_bytes` as a soft cap: writes evict the
  least valuable entries, and a background pass evicts any overshoot. Entries
  requested most often are kept longest (a W-TinyLFU policy). Bounded mode
  runs processes that track the cache's size, so a bounded cache must be
  configured on an instance, which starts them (see `ImagePipe.child_spec/1`):

      children = [
        {ImagePipe,
         name: MyApp.Images,
         sources: sources,
         cache:
           {ImagePipe.Cache.FileSystem,
            root: "/var/cache/image_pipe/processed",
            max_size_bytes: 5_000_000_000,
            node_id: "node-0"}},
        MyAppWeb.Endpoint
      ]

  To set up processed-image and originals caches, see
  [Caching processed images](caching-processed-images.md).

  ## Options

  #{NimbleOptions.docs(ImagePipe.Cache.FileSystem.Store.options_schema())}

  The adapter also accepts the shared `:max_body_bytes` option, a
  non-negative integer or `nil`. Responses larger than `:max_body_bytes` are
  delivered but not stored. The default `nil` stores responses of any size.
  """
  @behaviour ImagePipe.Cache
  @dialyzer :no_match
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Debug.Info
  @metadata_version 1

  @impl true
  @doc false
  defdelegate child_spec(opts), to: Store
  @doc false
  defdelegate registry_name(root), to: Store
  @doc false
  defdelegate paths(key, opts), to: Store
  @doc false
  defdelegate paths_from_hash(hash, opts), to: Store
  @doc false
  defdelegate read_descriptor(path), to: Store
  @doc false
  defdelegate delete_victims(victims, opts), to: Store
  @impl true
  defdelegate validate_options(opts), to: Store
  @impl true
  defdelegate write_chunk(state, chunk, opts), to: Store
  @impl true
  defdelegate commit_sink(state, opts), to: Store
  @impl true
  defdelegate abort_sink(state, opts), to: Store

  @impl true
  def open_sink(key, %Entry.Metadata{} = metadata, opts) do
    payload = metadata |> Map.from_struct() |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    Store.open_sink(key, payload, opts)
  end

  @doc """
  Reads a cached response and materializes its complete body as a binary.

  Returns `{:hit, entry}`, `:miss`, or `{:error, reason}`. The cached file is
  verified before reading, and its descriptor is closed before returning.
  """
  @impl true
  def get(key, opts) do
    case open(key, opts) do
      {:hit, entry} -> materialize(entry)
      other -> other
    end
  end

  defp materialize(entry) do
    {:hit,
     %{entry | body: entry.body |> CacheFile.stream() |> Enum.to_list() |> IO.iodata_to_binary()}}
  after
    Entry.close(entry)
  end

  @doc false
  def open(key, opts) do
    case Store.get(key, opts) do
      {:hit, file, metadata} -> decode_entry(file, metadata)
      other -> other
    end
  end

  defp decode_entry(file, metadata) do
    with {:ok, meta} <- validate_metadata(metadata),
         :ok <- Entry.validate_source_record(Map.get(metadata, :source_record)),
         {:ok, created_at} <- parse_created_at(meta.created_at) do
      {:hit,
       %Entry{
         body: file,
         content_type: meta.content_type,
         headers: meta.headers,
         created_at: created_at,
         representation: meta.representation,
         debug: meta.debug,
         source_record: Map.get(metadata, :source_record)
       }}
    else
      {:error, reason} ->
        CacheFile.close(file)
        handle_invalid_metadata(reason)
    end
  end

  defp validate_metadata(%{
         metadata_version: @metadata_version,
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us,
         debug: debug,
         representation: representation
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) and
              is_binary(body_filename) and is_integer(cost_us) and cost_us >= 0 do
    with :ok <- validate_metadata_debug(debug),
         :ok <- Entry.validate_content_type(content_type, representation),
         :ok <- validate_metadata_headers(headers) do
      {:ok,
       %{
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us,
         debug: debug,
         representation: representation
       }}
    end
  end

  defp validate_metadata(%{metadata_version: version}) when version != @metadata_version,
    do: {:error, :version_mismatch}

  defp validate_metadata(_metadata), do: {:error, :invalid_shape}

  defp validate_metadata_debug(debug) when is_struct(debug, Info) or is_nil(debug), do: :ok
  defp validate_metadata_debug(_debug), do: {:error, :invalid_debug}

  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp validate_metadata_headers(headers) do
    if Enum.all?(headers, &valid_metadata_header?/1) do
      :ok
    else
      {:error, :invalid_headers}
    end
  end

  defp valid_metadata_header?({name, value}), do: is_binary(name) and is_binary(value)
  defp valid_metadata_header?(_header), do: false

  defp parse_created_at(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> handle_invalid_metadata({:invalid_created_at, reason})
    end
  end
end
