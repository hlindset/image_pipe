r = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/img/"
{:ok, a} = Image.open(r <> "alpha.png"); {:ok, o} = Image.open(r <> "s300x200.png")
Image.write!(a, r <> "alpha.webp"); Image.write!(o, r <> "opaque.webp"); Image.write!(o, r <> "opaque.tif"); Image.write!(a, r <> "alpha.tif"); Image.write!(o, r <> "opaque.gif")
{:ok, big} = Image.open(r <> "s2000x1000.jpg"); Image.write!(big, r <> "big.png")
