alias Vix.Vips.Operation, as: O
alias ImagePipe.Transform.Operation.ProgressiveBlur
alias ImagePipe.Transform.{State, InputColorManagement, MemoryCopy}
bytes = File.read!(Path.join(__DIR__, "src/cmyka.tif"))
step = System.get_env("STEP", "all")
{:ok, img} = Vix.Vips.Image.new_from_buffer(bytes, access: :VIPS_ACCESS_SEQUENTIAL, fail_on: :VIPS_FAIL_ON_ERROR)
{:ok, st} = InputColorManagement.condition(%State{image: img})
IO.inspect(Vix.Vips.Image.header_value(st.image, "icc-profile-data") |> elem(0), label: "icc after cond")
{:ok, m} = MemoryCopy.copy(st.image)
IO.inspect(Vix.Vips.Image.header_value(m, "icc-profile-data") |> then(fn {:ok, b} -> byte_size(b); e -> e end), label: "icc after copy")
{:ok, st} = ProgressiveBlur.execute(%ProgressiveBlur{sigma: 5.0, angle: 0.0, start: 0.0, stop: 1.0}, %State{image: m})
for _ <- 1..5 do
IO.inspect(Vix.Vips.Image.header_value(st.image, "icc-profile-data") |> then(fn {:ok, b} -> byte_size(b); e -> e end), label: "icc after pb")
end
{:ok, out} = Vix.Vips.Image.copy_memory(st.image)
IO.inspect(Image.get_pixel!(out, 5, 5))
