alias Vix.Vips.{Image, MutableImage}
{:ok, lazy} = Image.new_from_file("priv/static/images/dog.jpg")
{:ok, mem} = Image.copy_memory(lazy)
IO.inspect(Image.header_value(mem, "ip-probe"), label: "before")
{:ok, _} = Image.mutate(mem, fn m -> MutableImage.set(m, "ip-probe", :gchararray, "mutated") end)
IO.inspect(Image.header_value(mem, "ip-probe"), label: "original after mutate (in-memory)")
{:ok, _} = Image.mutate(lazy, fn m -> MutableImage.set(m, "ip-probe", :gchararray, "mutated") end)
IO.inspect(Image.header_value(lazy, "ip-probe"), label: "original after mutate (lazy)")
