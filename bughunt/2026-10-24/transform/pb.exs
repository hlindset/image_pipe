alias Vix.Vips.Operation, as: O
alias ImagePipe.Transform.Operation.ProgressiveBlur
alias ImagePipe.Transform.State
path = Path.join(__DIR__, "src/cmyka.tif")
mode = System.get_env("MODE", "full")
{:ok, img} = Image.open(path, access: :sequential)
{:ok, img} = O.colourspace(img, :VIPS_INTERPRETATION_sRGB)
IO.inspect({Image.bands(img), Vix.Vips.Image.interpretation(img), Vix.Vips.Image.format(img), Image.has_alpha?(img)})
{:ok, img} = Vix.Vips.Image.copy_memory(img)
{:ok, st} = ProgressiveBlur.execute(%ProgressiveBlur{sigma: 5.0, angle: 0.0, start: 0.0, stop: 1.0}, %State{image: img})
IO.inspect({Image.bands(st.image), Vix.Vips.Image.format(st.image)})
{:ok, out} = Vix.Vips.Image.copy_memory(st.image)
IO.inspect(Image.get_pixel!(out, 5, 5))
