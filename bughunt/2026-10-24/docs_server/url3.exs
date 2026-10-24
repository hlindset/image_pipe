alias ImagePipe.URL, as: U
p = fn l, f -> r = try do f.() rescue e -> {:raised, e.__struct__, Exception.message(e)} end; IO.puts("#{l}: #{inspect(r, limit: 12, printable_limit: 300) |> String.slice(0, 500)}") end
key = String.duplicate("ab", 32); ek = String.duplicate("cd", 32)
ke = [keys: [key], source_encryption_keys: [ek]]
p.("iv keys no encrypt", fn -> U.new(U.config(ke)) |> U.url("x.jpg", iv: :random) end)
p.("bad iv", fn -> U.new(U.config(ke ++ [encrypt_source: true])) |> U.url("x.jpg", iv: "short") end)
p.("enc ok", fn -> U.new(U.config(ke ++ [encrypt_source: true])) |> U.url("x.jpg") end)
p.("enc wm", fn -> U.new(U.config(ke ++ [encrypt_source: true])) |> U.group(watermark_source: "logos/mark.png") |> U.url("x.jpg") end)
p.("enc invalid source with issues", fn -> U.new(U.config(ke ++ [encrypt_source: true])) |> U.url_with_issues("") end)
p.("encrypt_source empty", fn -> U.encrypt_source("", U.config(ke)) end)
p.("encrypt_source nonutf8", fn -> U.encrypt_source(<<0xff>>, U.config(ke)) end)
p.("encrypt_source bad opt", fn -> U.encrypt_source("x", U.config(ke), foo: 1) end)
p.("encrypt_source bad iv", fn -> U.encrypt_source("x", U.config(ke), iv: "short") end)
p.("encrypt_source iv det", fn -> U.encrypt_source("x", U.config(ke), iv: :deterministic) end)
p.("config enc no keys", fn -> U.config(source_encryption_keys: [ek]) end)
p.("config enc no keys + encrypt", fn -> U.config(source_encryption_keys: [ek], encrypt_source: true) end)
p.("ImagePipe.config enc no keys", fn -> ImagePipe.config(source_encryption_keys: [ek], allow_unsigned: true) end)
