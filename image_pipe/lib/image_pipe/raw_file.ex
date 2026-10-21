defmodule ImagePipe.RawFile do
  # File operations by path without the file server.
  #
  # `:file`'s path-based calls (rename, link, delete, mkdir, stat without
  # `:raw`, read and write without `:raw`) are served by the VM-wide
  # `:file_server_2` process, which serializes every caller. Under a burst of
  # cache writes its queue held over 100 messages, and a link took 8.6 ms
  # through it against 0.3 ms in the caller (image_plug-c9e0). These run in
  # the calling process instead: through the documented `:raw` options where
  # `:file` has them, and through `:prim_file`, the module the file server
  # itself calls, where it doesn't. Paths must be binaries.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc "Like `File.mkdir_p/1`."
  @spec make_dir_p(binary()) :: :ok | {:error, File.posix()}
  def make_dir_p(path) when is_binary(path) do
    case :prim_file.make_dir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if directory?(path), do: :ok, else: {:error, :enotdir}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        with true <- parent != path,
             :ok <- make_dir_p(parent) do
          make_dir_p(path)
        else
          false -> {:error, :enoent}
          error -> error
        end

      error ->
        error
    end
  end

  @doc "Like `File.mkdir/1`."
  @spec make_dir(binary()) :: :ok | {:error, File.posix()}
  def make_dir(path) when is_binary(path), do: :prim_file.make_dir(path)

  @doc "Like `File.rename/2`."
  @spec rename(binary(), binary()) :: :ok | {:error, File.posix()}
  def rename(source, destination) when is_binary(source) and is_binary(destination),
    do: :prim_file.rename(source, destination)

  @doc "Like `File.ln/2`."
  @spec make_link(binary(), binary()) :: :ok | {:error, File.posix()}
  def make_link(existing, new) when is_binary(existing) and is_binary(new),
    do: :prim_file.make_link(existing, new)

  @doc "Like `File.rm/1`."
  @spec delete(binary()) :: :ok | {:error, File.posix()}
  def delete(path) when is_binary(path), do: :prim_file.delete(path)

  @doc "Like `File.stat/2`."
  @spec stat(binary(), keyword()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path, opts \\ []) when is_binary(path) do
    with {:ok, info} <- :file.read_file_info(path, [:raw, time: time(opts)]),
         do: {:ok, File.Stat.from_record(info)}
  end

  @doc "Like `File.lstat/2`."
  @spec lstat(binary(), keyword()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path, opts \\ []) when is_binary(path) do
    with {:ok, info} <- :file.read_link_info(path, [:raw, time: time(opts)]),
         do: {:ok, File.Stat.from_record(info)}
  end

  @doc "Sets a file's access and modification times, in POSIX seconds."
  @spec set_times(binary(), integer()) :: :ok | {:error, File.posix()}
  def set_times(path, posix) when is_binary(path) and is_integer(posix),
    do: :prim_file.write_file_info(path, file_info(atime: posix, mtime: posix), time: :posix)

  @doc "Like `File.chmod/2`."
  @spec set_mode(binary(), non_neg_integer()) :: :ok | {:error, File.posix()}
  def set_mode(path, mode) when is_binary(path) and is_integer(mode),
    do: :prim_file.write_file_info(path, file_info(mode: mode), time: :posix)

  @doc "Like `File.read/1`."
  @spec read(binary()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path) when is_binary(path), do: :file.read_file(path, [:raw])

  @doc "Like `File.write/3`, with `:binary` implied."
  @spec write(binary(), iodata(), [atom()]) :: :ok | {:error, File.posix()}
  def write(path, data, modes \\ []) when is_binary(path),
    do: :file.write_file(path, data, [:raw, :binary | modes])

  @doc "Like `File.ls/1`."
  @spec list_dir(binary()) :: {:ok, [binary()]} | {:error, File.posix()}
  def list_dir(path) when is_binary(path) do
    with {:ok, names} <- :prim_file.list_dir(path),
         do: {:ok, Enum.map(names, &IO.chardata_to_string/1)}
  end

  defp directory?(path) do
    match?({:ok, file_info(type: :directory)}, :file.read_file_info(path, [:raw]))
  end

  defp time(opts), do: Keyword.get(opts, :time, :universal)
end
