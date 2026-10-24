Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = H.call(mount, :get, path)

alias ImagePipe.Execution
alias ImagePipe.Execution.Inputs
alias ImagePipe.Source

config = ImagePipe.Plug.Config.resolve(mount)
conn = Plug.Test.conn(:get, path)
{{:ok, request, source}, _meta} = ImagePipe.Plug.Request.parse(conn, config)

resolve_source = fn config ->
  with {:ok, parsed} <- ImagePipe.Source.Parser.translate(source, config),
       {:ok, src} <- Source.resolve(parsed, config, Source.runtime_opts(config)),
       do: {:ok, src, config}
end

inputs = %Inputs{headers: conn.req_headers, cookies: %{}}
{:ok, policy} = ImagePipe.Processing.prepare(request, config, "")
{:ok, src, _} = resolve_source.(config)

bench = fn name, f, n ->
  Enum.each(1..300, fn _ -> f.() end)
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  {:reductions, r0} = Process.info(self(), :reductions)
  Enum.each(1..n, fn _ -> f.() end)
  {:reductions, r1} = Process.info(self(), :reductions)
  IO.puts("#{String.pad_trailing(name, 44)} #{Float.round(t / n, 2)} us  #{div(r1 - r0, n)} red")
end

for _ <- 1..2 do
  bench.("Config.resolve", fn -> ImagePipe.Plug.Config.resolve(mount) end, 5000)
  bench.("Plug.Request.parse", fn -> ImagePipe.Plug.Request.parse(conn, config) end, 5000)
  bench.("Processing.prepare (policy)", fn -> ImagePipe.Processing.prepare(request, config, "") end, 5000)
  bench.("resolve_source (translate+resolve)", fn -> resolve_source.(config) end, 5000)
  bench.("Execution.identity_material", fn -> Execution.identity_material(request, policy, inputs, config) end, 5000)
  bench.("Execution.prepare + close", fn ->
    {:ok, ctx} = Execution.prepare(request, src, [], policy, inputs, config)
    Execution.close(ctx)
  end, 3000)
  {:ok, ctx} = Execution.prepare(request, src, [], policy, inputs, config)
  Execution.close(ctx)
  bench.("Source.prepare_cache_context", fn -> Source.prepare_cache_context(src, config) end, 5000)
  bench.("Representation.build", fn -> ImagePipe.Representation.build(ctx.source.identity, ctx.material, ctx.source.cache_semantics.byte_identity) end, 5000)
  bench.("Execution.open(hit)+close_output", fn ->
    {:ok, out} = Execution.open(ctx)
    Execution.close_output(out)
  end, 3000)
  bench.("full Plug.call 304", fn -> nil end, 1)
end
