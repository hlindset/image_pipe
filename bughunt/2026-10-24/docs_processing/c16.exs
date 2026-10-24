Code.require_file("/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/h.exs")
{:ok, s} = Vix.Vips.Image.new_from_file(H.root() <> "/g100_16.png"); IO.inspect({Vix.Vips.Image.format(s), Vix.Vips.Image.interpretation(s), Vix.Vips.Operation.getpoint(s, 1, 1)}, label: "SRC")
for p <- ["/brightness=40/src/g100_16.png", "/contrast=2/src/g100_16.png", "/src/g100_16.png"] do
  c = H.req(p)
  {:ok, i} = Vix.Vips.Image.new_from_buffer(c.resp_body)
  IO.inspect({p, Vix.Vips.Image.format(i), Vix.Vips.Operation.getpoint(i, 1, 1)}, label: "OUT")
end
