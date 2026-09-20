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
    case Map.fetch(Req.Utils.load_netrc(path), host) do
      {:ok, {username, password}} -> {:basic, username <> ":" <> password}
      :error -> nil
    end
  end

  defp value(auth, _host), do: auth
end
