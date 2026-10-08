defmodule ImagePipe.Source.Auth do
  @moduledoc false

  def freeze(opts, url) do
    case Keyword.fetch(opts, :auth) do
      :error -> opts
      {:ok, auth} -> Keyword.put(opts, :auth, value(auth, URI.parse(url).host))
    end
  end

  defp value(fun, host) when is_function(fun, 0), do: value(fun.(), host)

  defp value({module, fun, args}, host) when is_atom(module) and is_atom(fun) and is_list(args),
    do: value(apply(module, fun, args), host)

  defp value(:netrc, host),
    do: value({:netrc, System.get_env("NETRC") || Path.join(System.user_home!(), ".netrc")}, host)

  defp value({:netrc, path}, host) do
    case Map.fetch(netrc(path), host) do
      {:ok, {username, password}} -> {:basic, username <> ":" <> password}
      :error -> nil
    end
  end

  defp value(auth, _host), do: auth

  # Reading and parsing the file on every request is slow, and so is checking
  # it, so the parsed file is reused, with its size, modification time and
  # inode checked at most once a second. A changed file is read again.
  @netrc_check_ms 1_000

  defp netrc(path) do
    key = {__MODULE__, :netrc, path}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {identity, parsed, checked} ->
        if now - :atomics.get(checked, 1) < @netrc_check_ms,
          do: parsed,
          else: recheck_netrc(key, path, now, identity, parsed, checked)

      nil ->
        load_netrc(key, path, now)
    end
  end

  defp recheck_netrc(key, path, now, identity, parsed, checked) do
    :atomics.put(checked, 1, now)
    if file_identity(path) == identity, do: parsed, else: load_netrc(key, path, now)
  end

  defp load_netrc(key, path, now) do
    identity = file_identity(path)
    parsed = Req.Utils.load_netrc(path)
    checked = :atomics.new(1, [])
    :atomics.put(checked, 1, now)
    :persistent_term.put(key, {identity, parsed, checked})
    parsed
  end

  defp file_identity(path) do
    case :file.read_file_info(path, [:raw, {:time, :posix}]) do
      {:ok, info} ->
        %File.Stat{size: size, mtime: mtime, inode: inode} = File.Stat.from_record(info)
        {size, mtime, inode}

      {:error, _reason} ->
        :error
    end
  end
end
