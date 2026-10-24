alias ImagePipeServer.Config
dir = Path.expand(".")
key = String.duplicate("0123abcd", 8)
key2 = String.duplicate("4567ef01", 8)
File.mkdir_p!(Path.join(dir, "imgs"))
none = Path.join(dir, "nonexistent.toml")

try_load = fn label, env ->
  res =
    try do
      c = Config.load!(env, none)
      {:ok, c}
    rescue
      e -> {:error, Exception.message(e)}
    end
  IO.puts("== #{label}")
  case res do
    {:ok, c} -> IO.inspect(c, limit: :infinity, printable_limit: 300, pretty: true, label: "ok") |> then(fn _ -> :ok end)
    {:error, m} -> IO.puts("ERROR: " <> m)
  end
  res
end

base = %{"IPS_URL__ALLOW_UNSIGNED" => "true"}
toml = fn s -> Map.put(base, "IPS_CONFIG_TOML", s) end

# Doc example small file
doc_file = """
[url]
keys = ["#{key}"]

[sources.static]
adapter = "file"
match = "path"
root = "#{dir}/imgs"
root_id = "static"

[sources.tmdb]
adapter = "http"
match = { prefix = "tmdb" }
base_url = "https://image.tmdb.org/t/p/original"
path_pattern = '[a-zA-Z0-9_-]+\\.(jpg|jpeg|png|webp)'
stable = "immutable"
cache_policy = { storage = "allow" }

[cache.output]
root = "#{dir}/cache"
max_size_bytes = 10_000_000_000

[processing]
quality = 82

[pool]
max_concurrency = 8
max_queue = 16
"""
{:ok, c} = try_load.("doc small file", %{"IPS_CONFIG_TOML" => doc_file})
IO.inspect(Keyword.take(c.image_pipe.options, [:max_remembered_originals, :cache]), label: "cache opts")
