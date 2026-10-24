Mix.ensure_application!(:runtime_tools)
Mix.ensure_application!(:tools)
Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()

modes = %{
  "get" => fn -> %{status: 200} = H.call(mount, :get, path) end,
  "304" => fn -> %{status: 304} = H.call(mount, :get, path, [{"if-none-match", etag}]) end
}

name = System.get_env("PROF", "304")
f = modes[name]
Enum.each(1..200, fn _ -> f.() end)
out = String.to_charlist(Path.join(__DIR__, "fprof.trace"))
:fprof.apply(fn -> Enum.each(1..50, fn _ -> f.() end) end, [], file: out)
:fprof.profile(file: out)

:fprof.analyse(
  dest: String.to_charlist(Path.join(__DIR__, "fprof_#{name}.txt")),
  totals: true,
  sort: :acc,
  callers: false,
  details: false
)
