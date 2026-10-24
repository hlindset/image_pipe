for {n, v} <- [{"g64", 64}, {"g100", 100}, {"g127", 127}, {"g128", 128}, {"g192", 192}, {"g255", 255}] do
  {:ok, i} = Image.new(20, 20, color: [v, v, v])
  Image.write!(i, "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/img/#{n}.png")
end
{:ok, i} = Image.new(20, 20, color: [100, 100, 100])
{:ok, i} = Vix.Vips.Operation.cast(i, :VIPS_FORMAT_USHORT)
{:ok, i} = Vix.Vips.Operation.linear(i, [257.0], [0.0])
{:ok, i} = Vix.Vips.Operation.cast(i, :VIPS_FORMAT_USHORT)
{:ok, i} = Vix.Vips.Operation.copy(i, interpretation: :VIPS_INTERPRETATION_RGB16)
Vix.Vips.Image.write_to_file(i, "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/img/g100_16.png")
{:ok, i} = Image.new(20, 20, color: [100])
Image.write!(i, "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/img/gray100.png")
{:ok, i} = Image.new(20, 20, color: [100, 100, 100, 0])
Image.write!(i, "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/img/transp.png")
