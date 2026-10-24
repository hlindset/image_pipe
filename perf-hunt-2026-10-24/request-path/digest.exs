Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = System.get_env("REQPATH", "/w=300/format=webp/src/image.jpg")
%{status: 200} = H.call(mount, :get, path)

alias ImagePipe.Execution
alias ImagePipe.Execution.Inputs
alias ImagePipe.Source
alias ImagePipe.MaterialDigest

config = ImagePipe.Plug.Config.resolve(mount)
conn = Plug.Test.conn(:get, path)
{{:ok, request, source}, _meta} = ImagePipe.Plug.Request.parse(conn, config)
{:ok, parsed} = ImagePipe.Source.Parser.translate(source, config)
{:ok, src} = Source.resolve(parsed, config, Source.runtime_opts(config))
inputs = %Inputs{headers: conn.req_headers, cookies: %{}}
{:ok, policy} = ImagePipe.Processing.prepare(request, config, "")
{:ok, ctx} = Execution.prepare(request, src, [], policy, inputs, config)
Execution.close(ctx)

key_data = [
  representation_schema: 1,
  source_identity: ctx.source.identity,
  byte_identity: ctx.source.cache_semantics.byte_identity,
  representation: ctx.material.representation,
  storage_only: ctx.material.storage_only
]

canonical = MaterialDigest.canonical(key_data)
bin = :erlang.term_to_binary(canonical, [:deterministic])
IO.puts("key_data flat words: #{:erts_debug.flat_size(key_data)}, t2b bytes: #{byte_size(bin)}")
IO.inspect(ctx.material.representation, limit: :infinity, printable_limit: 200, label: "representation")

bench = fn name, f, n ->
  Enum.each(1..300, fn _ -> f.() end)
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  {:reductions, r0} = Process.info(self(), :reductions)
  Enum.each(1..n, fn _ -> f.() end)
  {:reductions, r1} = Process.info(self(), :reductions)
  IO.puts("#{String.pad_trailing(name, 44)} #{Float.round(t / n, 2)} us  #{div(r1 - r0, n)} red")
end

for _ <- 1..2 do
  bench.("canonical(key_data)", fn -> MaterialDigest.canonical(key_data) end, 10000)
  bench.("term_to_binary deterministic", fn -> :erlang.term_to_binary(canonical, [:deterministic]) end, 10000)
  bench.("term_to_binary plain", fn -> :erlang.term_to_binary(canonical) end, 10000)
  bench.("sha256 of t2b", fn -> :crypto.hash(:sha256, bin) end, 10000)
  bench.("Representation.build", fn -> ImagePipe.Representation.build(ctx.source.identity, ctx.material, ctx.source.cache_semantics.byte_identity) end, 10000)
  bench.("Execution.identity_material", fn -> Execution.identity_material(request, policy, inputs, config) end, 10000)
end
