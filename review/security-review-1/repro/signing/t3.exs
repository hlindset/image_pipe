ka = String.duplicate("ab", 32); kb = String.duplicate("bc", 32); e = String.duplicate("cd", 32)
base = ImagePipe.config(keys: [ka], source_encryption_keys: [e], sources: [])
mount_b = ImagePipe.Config.put_url_options(base, keys: [kb])
# A's builder makes a concealed URL with a watermark
a_url_cfg = ImagePipe.URL.config(keys: [ka], source_encryption_keys: [e], encrypt_source: true)
{:ok, a_url} = ImagePipe.URL.new(a_url_cfg) |> ImagePipe.URL.group(resize: [width: 200]) |> ImagePipe.URL.url("https://private.example/x.jpg?X-Amz-Signature=secret")
IO.puts a_url
[_, tok] = Regex.run(~r{enc/(.*)$}, a_url)
# B's key holder signs their own path around A's token
b_url_cfg = ImagePipe.URL.config(keys: [kb])
b_path = ImagePipe.URL.sign_path("/w=4000/enc/" <> tok, b_url_cfg)
IO.puts b_path
{sig, sp} = ImagePipe.API.Path.split_signature(b_path)
IO.inspect ImagePipe.Security.verify(sig, sp, mount_b.options), label: "verify on mount B"
IO.inspect ImagePipe.Security.decrypt_source(tok, mount_b.options), label: "decrypt on mount B"
