defmodule BH.Deny do
  @behaviour ImagePipe.Source
  def identifiers(_), do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]
  def validate_options(o), do: {:ok, o}
  def resolve(s, _, _), do: (IO.inspect(s, label: "resolve"); {:error, {:source, :denied_path}})
  def fetch(_, _, _), do: raise("no")
end
import Plug.Test
config = ImagePipe.Plug.init(allow_unsigned: true, sources: [path: [adapter: BH.Deny, match: :path, options: []], http: [adapter: BH.Deny, match: [scheme: "https"], options: []]])
for path <- ["/src64/" <> Base.url_encode64(<<0xFF, 0xFE>>, padding: false), "/src/%FF%FE", "/src/a%C3", "/src64/" <> Base.url_encode64("https://x/\xFF", padding: false),
             "/wm-src64=" <> Base.url_encode64(<<0xFF>>, padding: false) <> "/src/a.jpg",
             "/src/%2F", "/src/%2F%2Fhost/a", "/src/https:%2F%2Fu:p@h/a", "/src/https://h:0/a", "/src/https:%2F%2F%5B::1%5D/a"] do
  try do
    conn = ImagePipe.Plug.call(conn(:get, path), config)
    IO.puts("#{inspect path} -> #{conn.status} #{inspect(conn.resp_body) |> String.slice(0, 200)}")
  rescue e -> IO.puts("#{inspect path} RAISE #{Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 800)}")
  end
end
