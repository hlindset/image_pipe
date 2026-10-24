dump = fn name, schema ->
  IO.puts("##### #{name}")
  for {k, spec} <- schema do
    IO.puts("#{k} | default=#{inspect(spec[:default])} | req=#{spec[:required]} | #{String.replace(spec[:doc] || "", "\n", " ")}\n")
  end
end
dump.("S3", ImagePipe.Source.S3.config_schema())
dump.("Store", ImagePipe.Cache.FileSystem.Store.options_schema())
dump.("shared", ImagePipe.Cache.shared_options_schema())
