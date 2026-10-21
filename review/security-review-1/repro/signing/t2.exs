key = String.duplicate("ab", 32)
ekey = String.duplicate("cd", 32)
base = ImagePipe.config(keys: [key], source_encryption_keys: [ekey], sources: [])
try do
  ImagePipe.Config.put_url_options(base, keys: [])
  IO.puts "NO RAISE"
rescue
  e -> IO.puts "raised: " <> Exception.message(e)
end
# encrypt_source mount override without keys?
c = ImagePipe.Config.put_url_options(base, keys: [String.duplicate("ef", 32)])
IO.inspect Keyword.fetch!(c.options, :keys), label: "keys"
