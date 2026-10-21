key = String.duplicate("ab", 32)
ekey = String.duplicate("cd", 32)
cfg = ImagePipe.URL.config(keys: [key], source_encryption_keys: [ekey], encrypt_source: true)
b = ImagePipe.URL.new(cfg) |> ImagePipe.URL.group(resize: [width: 400])
{:ok, url} = ImagePipe.URL.url(b, "https://example.com/a.jpg")
IO.puts url
opts = cfg.options
alias ImagePipe.API.Path, as: P
{sig, sp} = P.split_signature(url)
IO.inspect ImagePipe.Security.verify(sig, sp, opts)
[_, tok] = Regex.run(~r{enc/(.*)$}, url)
IO.inspect ImagePipe.Security.decrypt_source(tok, opts)
# flip a byte of ciphertext
{:ok, raw} = Base.url_decode64(tok, padding: false)
<<h::binary-size(20), b0, rest::binary>> = raw
bad = Base.url_encode64(<<h::binary, Bitwise.bxor(b0, 1), rest::binary>>, padding: false)
IO.inspect ImagePipe.Security.decrypt_source(bad, opts)
# random mode
cfg2 = ImagePipe.URL.config(keys: [key], source_encryption_keys: [ekey], encrypt_source: true, iv_mode: :random)
b2 = ImagePipe.URL.new(cfg2) |> ImagePipe.URL.group(resize: [width: 400])
IO.puts ImagePipe.URL.url!(b2, "https://example.com/a.jpg")
IO.puts ImagePipe.URL.url!(b2, "https://example.com/a.jpg")
