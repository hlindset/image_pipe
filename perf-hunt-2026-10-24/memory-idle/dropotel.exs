# Stop the OTel exporter stack (unused when tracing is off) and purge its modules, to measure what it holds.
apps = [:opentelemetry_exporter, :tls_certificate_check, :ssl_verify_fun, :grpcbox, :chatterbox, :acceptor_pool, :ctx, :gproc, :opentelemetry]
for a <- apps, do: IO.inspect({a, Application.stop(a)})
mods = for a <- apps, m <- (Application.spec(a, :modules) || []), do: m
for m <- mods, :code.is_loaded(m) != false do
  :code.purge(m); :code.delete(m); :code.purge(m)
end
:persistent_term.erase(:pubkey_os_cacerts)
for {k, _} <- :persistent_term.get(), is_atom(k) and String.starts_with?(Atom.to_string(k), "__$tls_certificate_check"), do: :persistent_term.erase(k)
Enum.each(Process.list(), &:erlang.garbage_collect/1)
IO.puts("purged #{length(mods)} modules")
