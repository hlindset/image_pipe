defmodule ZH do
  use ImagePipe.URL.Helpers
  def a, do: image_url("cat.jpg", new: [filename: "cat"], group: [resize: [width: 400, height: 300, fit: :cover]], group: [blur: 2], output: [format: :webp])
  def b, do: image_url("cat.jpg", group: [resize: [width: 300, fit: :fill]])
  def c(w), do: image_url("cat.jpg", group: [resize: [width: w, fit: :cover]])
  def d(f), do: image_url("cat.jpg", group: [resize: [width: 300, fit: f]])
end
IO.puts(ZH.a()); IO.puts(ZH.b()); IO.puts(ZH.c(10)); IO.puts(ZH.d(:fill))
defmodule ZH2 do
  use ImagePipe.URL.Helpers, on_invalid: :raise
  def d(f), do: image_url("cat.jpg", group: [resize: [width: 300, fit: f]])
end
try do ZH2.d(:fill) rescue e -> IO.inspect(e) end
