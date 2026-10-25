defmodule ImagePipe.Cache.FileSystem do
  @moduledoc """
  Stores processed images as files on local disk. The `cache` option takes
  its options, and needs an instance, which starts the processes that track
  the cache's size (see `ImagePipe.child_spec/1`):

      children = [
        {ImagePipe,
         name: MyApp.Images,
         sources: sources,
         cache: [root: "/var/cache/image_pipe/processed", max_size_bytes: 5_000_000_000]},
        MyAppWeb.Endpoint
      ]

  `:max_size_bytes` caps the disk the stored entries take: a write evicts
  entries to make room before it's stored, or is rejected. The cache keeps the entries that
  are requested often and took the most work to make for their size.

  To set up the cache, see
  [Caching processed images](caching-processed-images.md).

  ## Options

  #{NimbleOptions.docs(ImagePipe.Cache.FileSystem.Store.options_schema())}

  The processed-image cache also accepts `:max_body_bytes`, a
  non-negative integer or `nil`. Responses larger than `:max_body_bytes` are
  delivered but not stored. The default `nil` stores responses of any size.
  """
  @dialyzer :no_match
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Debug.Info

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
  @doc false
  defdelegate validate_options(opts), to: Store
  @doc false
  defdelegate write_chunk(state, chunk, opts), to: Store
  @doc false
  defdelegate commit_sink(state, opts), to: Store
  @doc false
  defdelegate abort_sink(state, opts), to: Store
  @doc false
  defdelegate usage(opts), to: Store

  @doc false
  def open_sink(key, %Entry.Metadata{} = metadata, opts) do
    payload = metadata |> Map.from_struct() |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    Store.open_sink(key, payload, opts)
  end

  @doc """
  Reads a cached response and materializes its complete body as a binary.

  Returns `{:hit, entry}`, `:miss`, or `{:error, reason}`. The cached file's
  size is checked before reading, and its descriptor is closed before returning.
  """
  # Hosts call this with their own options. The Plug reads through `open/2`
  # with options validated once with the cache configuration.
  def get(key, opts) do
    with {:ok, opts} <- validate_options(opts),
         {:hit, entry} <- open(key, opts) do
      materialize(entry)
    end
  end

  defp materialize(entry) do
    with {:ok, file} <- CacheFile.ensure_open(entry.body) do
      try do
        {:hit,
         %{entry | body: file |> CacheFile.stream() |> Enum.to_list() |> IO.iodata_to_binary()}}
      after
        CacheFile.close(file)
      end
    end
  end

  @doc false
  # Counts a request's miss of `key` toward admitting its entry.
  def missed(key, opts), do: Store.miss(key, opts)

  @doc false
  def open(key, opts, sighting? \\ true), do: Store.get(key, opts, sighting?, &decode_entry/1)

  # The entry, without its body, that stored metadata describes. The cache
  # remembers it, so a hit from memory doesn't validate the metadata again.
  defp decode_entry(metadata) do
    with {:ok, meta} <- validate_metadata(metadata),
         {:ok, created_at} <- parse_created_at(meta.created_at) do
      {:ok,
       %Entry{
         body: nil,
         content_type: meta.content_type,
         headers: meta.headers,
         created_at: created_at,
         representation: meta.representation,
         debug: meta.debug
       }}
    else
      {:error, reason} -> handle_invalid_metadata(reason)
    end
  end

  defp validate_metadata(%{
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

  defp validate_metadata(_metadata), do: {:error, :invalid_shape}

  defp validate_metadata_debug(debug) when is_struct(debug, Info) or is_nil(debug), do: :ok
  defp validate_metadata_debug(_debug), do: {:error, :invalid_debug}

  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp validate_metadata_headers(headers) do
    case Entry.cacheable_headers(headers) do
      {:ok, _headers} -> :ok
      {:error, _reason} -> {:error, :invalid_headers}
    end
  end

  defp parse_created_at(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> handle_invalid_metadata({:invalid_created_at, reason})
    end
  end
end
