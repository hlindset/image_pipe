defmodule ImagePipe.Cache.SharedFileSystem.Directory do
  @moduledoc false

  @errors %{
    "enoent" => :enoent,
    "enotdir" => :enotdir,
    "eacces" => :eacces,
    "emfile" => :emfile,
    "enfile" => :enfile,
    "enomem" => :enomem,
    "directory_io" => :directory_io
  }

  # Called only inside the isolated I/O helper. The outer operation deadline
  # retains its reservation while this process waits for the child to exit.
  def list(path, limit) do
    with {:ok, output} <- execute([path, Integer.to_string(limit)], 33 * limit + 64) do
      decode(output, limit)
    end
  end

  def sweep(trash, limit) do
    with {:ok, output} <- execute([trash, Integer.to_string(limit), "--sweep"], 128) do
      decode_sweep(output, limit)
    end
  end

  defp execute(args, bytes) do
    executable = Path.join(to_string(:code.priv_dir(:image_pipe)), "shared_cache/list_directory")
    with {:ok, port} <- open(executable, args), do: collect(port, bytes, [])
  end

  defp open(executable, args) do
    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :use_stdio,
       :stderr_to_stdout,
       args: args
     ])}
  rescue
    ErlangError -> {:error, :directory_helper_unavailable}
  end

  defp decode_sweep(output, limit) do
    case String.split(output) do
      ["S", inspected, removed, errors, limited] when limited in ["0", "1"] ->
        with {inspected, ""} when inspected >= 0 and inspected <= limit <-
               Integer.parse(inspected),
             {removed, ""} when removed >= 0 and removed <= inspected <- Integer.parse(removed),
             {errors, ""} when errors >= 0 <- Integer.parse(errors) do
          {:ok,
           %{inspected: inspected, removed: removed, errors: errors, limited: limited == "1"}}
        else
          _invalid -> {:error, :directory_helper_failed}
        end

      ["E", error] ->
        {:error, Map.get(@errors, error, :directory_helper_failed)}

      _invalid ->
        {:error, :directory_helper_failed}
    end
  end

  defp collect(port, remaining, chunks) do
    receive do
      {^port, {:data, data}} when byte_size(data) <= remaining ->
        collect(port, remaining - byte_size(data), [data | chunks])

      {^port, {:data, _data}} ->
        # Keep waiting for actual exit without retaining oversized output.
        collect(port, -1, [])

      {^port, {:exit_status, 0}} when remaining >= 0 ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _status}} ->
        {:error, :directory_helper_failed}
    end
  end

  defp decode(output, limit) do
    case output |> String.split("\n", trim: true) |> Enum.reverse() do
      ["E " <> error | _names] ->
        {:error, Map.get(@errors, error, :directory_helper_failed)}

      [<<status, " ", count::binary>> | names] when status in [?C, ?L] ->
        decode_names(status, count, names, limit)

      _invalid ->
        {:error, :directory_helper_failed}
    end
  end

  defp decode_names(status, count, names, limit) do
    with {inspected, ""} when inspected >= 0 and inspected <= limit <- Integer.parse(count),
         true <- length(names) <= inspected,
         true <- Enum.all?(names, &Regex.match?(~r/\A[0-9a-f]{32}\z/, &1)) do
      completeness =
        case status do
          ?C -> :complete
          ?L -> :limited
        end

      {:ok, Enum.sort(names), completeness, inspected}
    else
      _invalid -> {:error, :directory_helper_failed}
    end
  end
end
