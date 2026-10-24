alias ImagePipe.API.{Parser, Path}
p = fn path ->
  {:ok, lexed} = Path.extract(path, "")
  case Parser.parse(lexed, []) do
    {:ok, r} -> %{r | ignored: []}
    e -> e
  end
end
pairs = [
  {"/w=100/h=100/crop=100,100/src/a", "/w=100/h=100/crop=100.0,100.0/src/a"},
  {"/region=0,0,10,10/src/a", "/region=0.0,0,10,10/src/a"},
  {"/rotate=90/src/a", "/rotate=90.0/src/a"},
  {"/rotate=90/src/a", "/rotate=450/src/a"},
  {"/w=100/h=100/fit=cover/anchor-offset=10,0/src/a", "/w=100/h=100/fit=cover/anchor-offset=10.0,0/src/a"},
  {"/blur=2/src/a", "/blur=2.0/src/a"},
  {"/brightness=5/src/a", "/brightness=05/src/a"},
  {"/w=100/src/a", "/w=0100/src/a"},
  {"/w=100/dpr=2/src/a", "/w=100/dpr=2.0/src/a"},
  {"/crop-ratio=1.5/src/a", "/crop-ratio=3:2/src/a"},
  {"/pad=10/src/a", "/pad=10,10,10,10/src/a"},
  {"/bg=fff/pad=1/src/a", "/bg=FFFFFF/pad=1/src/a"},
  {"/trim=fff,0/src/a", "/trim=fff,0.0/src/a"},
  {"/trim=fff/src/a", "/trim=fff,0/src/a"},
  {"/w=100/h=100/fit=cover/anchor-offset=0pct,0/src/a", "/w=100/h=100/fit=cover/anchor-offset=0,0/src/a"},
  {"/w=100/h=100/fit=cover/anchor-offset=-0,0/src/a", "/w=100/h=100/fit=cover/anchor-offset=0,0/src/a"},
  {"/w=100/h=100/fit=cover/anchor-offset=-0.0,0/src/a", "/w=100/h=100/fit=cover/anchor-offset=0,0/src/a"},
  {"/rotate=-0.0/w=1/src/a", "/w=1/src/a"},
  {"/q=80/src/a", "/q=080/src/a"},
  {"/page=1/src/a", "/page=01/src/a"},
  {"/sharpen=1/src/a", "/sharpen=1.0/src/a"},
  {"/pixelate=1/src/a", "/src/a"},
  {"/detect=all/w=10/h=10/fit=cover/anchor=smart/src/a", "/detect=all:1/w=10/h=10/fit=cover/anchor=smart/src/a"},
  {"/zoom=2/w=10/src/a", "/zoom=2,2/w=10/src/a"},
  {"/w=100/h=100/crop=50pct,50pct/src/a", "/w=100/h=100/crop=50.0pct,50pct/src/a"},
  {"/gradient=1,red/src/a", "/gradient=1,red,down/src/a"},
  {"/gradient=1,red,down/src/a", "/gradient=1,red,0/src/a"},
  {"/gradient=1,red,360/src/a", "/gradient=1,red,0/src/a"},
]
for {a, b} <- pairs do
  ra = p.(a); rb = p.(b)
  IO.puts("#{a}  vs  #{b}: strict=#{ra === rb} loose=#{ra == rb} #{if match?({:error,_}, ra) or match?({:error,_}, rb), do: inspect({ra,rb}, limit: 5), else: ""}")
  if ra == rb and ra !== rb, do: IO.inspect({ra.groups, rb.groups}, label: "DIFF")
end
