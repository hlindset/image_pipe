Code.require_file("h.exs", __DIR__)
alias Vix.Vips.Operation, as: O
for _ <- 1..5 do
img = H.noise(37, 53)
{:ok, img} = Vix.Vips.Image.copy_memory(img)
{:ok, r} = O.rot(img, :VIPS_ANGLE_D90)   # r is stored (53x37), display = img? no: let display = rot90(stored)
# display = img; stored = rot270(img) so that rot90(stored)=img
{:ok, stored} = O.rot(img, :VIPS_ANGLE_D270)
{:ok, a} = O.resize(img, 20/37, vscale: 29/53)
{:ok, b} = O.resize(stored, 29/53, vscale: 20/37)
{:ok, b} = O.rot(b, :VIPS_ANGLE_D90)
IO.inspect(H.maxdiff(a, b), label: "diff")
_ = r
end
