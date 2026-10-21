alias ImagePipe.Source.HTTP.{AddressPolicy, TargetGuard}
p = AddressPolicy.compile([])
{:ok, hosts} = TargetGuard.allowed_hosts(["assets.example.com", "127.1", "2130706433", "0x7f.1", "[::ffff:127.0.0.1]", "[64:ff9b::a9fe:a9fe]"])
res = fn _ -> {:ok, [{93,184,216,34}]} end
for u <- ["http://assets.example.com/x", "https://assets.example.com/x", "http://127.1/", "http://2130706433/", "http://0x7f.1/", "http://[::ffff:127.0.0.1]/", "http://[64:ff9b::a9fe:a9fe]/", "http://ASSETS.example.com./x"] do
  IO.inspect({u, TargetGuard.validate(u, hosts, p, res)})
end
for ip <- [{192,0,0,170}, {192,88,99,1}, {0x2001,0,0x4136,0xe378,0x8000,0x63bf,0x3fff,0xfdd2}, {0x64,0xff9b,1,0,0,0,0x0a00,1}, {0,0,0,0,0,0,0x7f00,1}, {0xfec0,0,0,0,0,0,0,1}, {0x100,0,0,0,0,0,0,1}, {0xfd00,0xec2,0,0,0,0,0,0x254}] do
  IO.inspect({ip, AddressPolicy.classify(ip)})
end
for s <- ["127.1", "2130706433", "0x7f.1", "0177.0.0.1", "127.0.0.1.", "::ffff:127.0.0.1"] do
  IO.inspect({s, :inet.parse_address(String.to_charlist(s)), :inet.getaddrs(String.to_charlist(s), :inet)})
end
IO.inspect(URI.parse("http://a.example.com\\@b.example.com/"))
IO.inspect(URI.parse("http://a.example.com%2f@b/"))
