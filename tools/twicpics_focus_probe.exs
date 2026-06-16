# TwicPics focus-placement probe
# =================================================================
# Empirically determines where TwicPics places the focus point after
# `cover`, `contain`, `inside` (and any other chain you add), by reading the
# answer straight off the pixels.
#
# Idea: the source is a grid of uniquely-coloured cells. Each cell's colour
# encodes its (col,row): `{round(col*255/(cols-1)), round(row*255/(rows-1)), 255}`.
# We set `focus=` on a chosen cell's centre, run the op under test, then a small
# trailing `crop` (the focus *consumer*). We sample the centre pixel of the
# result and decode which cell it is:
#   - matches the focused cell  -> focus tracked correctly through the op
#   - transparent (alpha ~ 0)   -> focus landed on `inside`'s letterbox padding
#   - a different cell          -> focus placement diverged; the cell tells you how
#
# Run inside the project so Req/Image/Vix are on the path:
#   mix run tools/twicpics_focus_probe.exs generate          # writes the source PNG
#   # ...upload tmp/twic_focus/grid.png to your TwicPics origin, set TWIC_BASE...
#   TWIC_BASE="https://<sub>.twic.pics/<path>/grid.png" \
#     mix run tools/twicpics_focus_probe.exs run             # fetch + decode + report
#   mix run tools/twicpics_focus_probe.exs urls              # just print the URLs
#
# Everything below the @config / @cases attributes is configurable.

defmodule TwicFocusProbe do
  # ---- configuration ------------------------------------------------------
  @config %{
    # Bare URL of the hosted grid image (no query). Override via TWIC_BASE.
    base: System.get_env("TWIC_BASE", "https://imagepipe.twic.pics/b7g72c.png"),
    # columns x rows of cells
    grid: {4, 4},
    # source pixels per cell -> source is 400x400 here
    cell: {100, 100},
    # trailing guided crop; small so its centre pixel is the focus
    final_crop: {12, 12},
    # force lossless pixels at dpr 1; ensure NO path default manip
    suffix: "output=png/dpr=1",
    out_dir: "tmp/twic_focus"
  }

  # Each case: focus on `target` cell centre -> `op` -> trailing crop (the consumer).
  # `op: nil` is the control (focus straight into the crop, no intermediate transform).
  # Add/edit freely. `expect` is what a faithful "carry focus with the image" would give.
  # A case is either `target`-based (focus auto-set on that cell's centre, then
  # `op`, then the trailing crop) or `chain`-based (a verbatim manipulation chain,
  # for what the target form can't express, e.g. a prefix op before `focus`).
  # `expect` is the cell a faithful "carry focus with the image" port would yield;
  # the colour identifies the *content*, so a focus that tracks its cell decodes
  # back to `target` no matter how the op moves/rotates/mirrors the pixels.
  @cases [
    # --- scale / cover-crop / canvas carry-through ---
    %{name: "control focus->crop (no op)", op: nil, target: {1, 1}, expect: {1, 1}},
    %{name: "cover square, corner focus", op: "cover=150x150", target: {0, 0}, expect: {0, 0}},
    %{name: "cover square, centre focus", op: "cover=150x150", target: {2, 2}, expect: {2, 2}},
    %{name: "cover WIDE (v-crop)", op: "cover=200x100", target: {1, 1}, expect: {1, 1}},
    %{name: "cover TALL (h-crop)", op: "cover=100x200", target: {2, 1}, expect: {2, 1}},
    %{
      name: "contain square (fit, no pad)",
      op: "contain=150x150",
      target: {3, 0},
      expect: {3, 0}
    },
    %{name: "inside square (pads to box)", op: "inside=150x150", target: {0, 3}, expect: {0, 3}},
    %{name: "inside WIDE (letterbox L/R)", op: "inside=200x100", target: {2, 2}, expect: {2, 2}},
    %{name: "inside TALL (letterbox T/B)", op: "inside=100x200", target: {1, 2}, expect: {1, 2}},

    # --- rotation / reflection: focus should turn/flip with the image ---
    %{name: "turn 90", op: "turn=90", target: {1, 0}, expect: {1, 0}},
    %{name: "turn 270", op: "turn=270", target: {0, 1}, expect: {0, 1}},
    %{name: "turn 180", op: "turn=180", target: {3, 3}, expect: {3, 3}},
    # flip axis values (x / y) may need adjusting to TwicPics' spelling.
    %{name: "flip x (horizontal)", op: "flip=x", target: {0, 1}, expect: {0, 1}},
    %{name: "flip y (vertical)", op: "flip=y", target: {1, 0}, expect: {1, 0}},

    # --- zoom: focus is the zoom centre, dims preserved ---
    %{name: "zoom 2x toward focus", op: "zoom=2", target: {2, 2}, expect: {2, 2}},

    # --- focus persists across multiple consumers (cover -> crop -> crop) ---
    %{name: "double consumer", op: "cover=200x200/crop=120x120", target: {1, 1}, expect: {1, 1}},

    # --- non-commutativity: identical focus=75x75, resize before vs after ---
    # resize first => 75x75 is in the 200x200 frame => source (150,150) = cell (1,1)
    %{
      name: "noncommute resize/focus",
      chain: "resize=50p/focus=75x75/crop=12x12",
      expect: {1, 1}
    },
    # focus first => 75x75 is in the 400x400 source => source (75,75) = cell (0,0), carried
    %{
      name: "noncommute focus/resize",
      chain: "focus=75x75/resize=50p/crop=12x12",
      expect: {0, 0}
    },

    # --- out-of-bounds (CONFIRMED against live TwicPics). Source is 400x400, cells
    # 100px, so cell (3,3) is the bottom-right corner.
    # CONFIRMED: a positive coordinate past the far edge CLAMPS to the edge.
    %{name: "oob px beyond extent", chain: "focus=500x500/crop=12x12", expect: {3, 3}},
    # CONFIRMED: relative >100% also clamps (NOT rejected) — our parser currently
    # rejects ratio>1, which is the divergence #321 fixes (clamp instead).
    %{name: "oob relative >100%", chain: "focus=150px150p/crop=12x12", expect: {3, 3}},
    # px on the very last pixel (edge, in-bounds) — 0-based corner convention.
    %{name: "edge last pixel", chain: "focus=399x399/crop=12x12", expect: {3, 3}},
    # CONFIRMED: a negative coordinate is REJECTED (HTTP 404). `expect` can't encode a
    # reject, so this row shows "??? {:http, 404}" — that IS the expected signal.
    %{name: "oob negative", chain: "focus=-50x-50/crop=12x12", expect: {0, 0}},
    # reset recovers from an OOB focus: crop@coords resets to the region centre (150,150)
    # = cell (1,1), regardless of the prior OOB focus.
    %{
      name: "reset after oob",
      chain: "focus=500x500/crop=100x100@100x100/crop=12x12",
      expect: {1, 1}
    }
    # NOT probed (structurally impossible in TwicPics — see notes): focus "removed by a
    # crop" or "moved OOB by a transform". Every consumer centres on the focus, pad moves
    # it inward, scale is proportional, turn/flip stay in-frame — so no op ejects an
    # in-bounds focus. OOB only ever originates at set time.
  ]

  # ---- entrypoint ---------------------------------------------------------
  def main(["generate"]), do: generate()
  def main(["run"]), do: run()
  def main(["urls"]), do: Enum.each(@cases, &IO.puts(url_for(&1)))
  def main(_), do: IO.puts("usage: generate | run | urls")

  # ---- source generation --------------------------------------------------
  def generate do
    {cols, rows} = @config.grid
    {cw, ch} = @config.cell
    File.mkdir_p!(@config.out_dir)

    base = Image.new!(cols * cw, rows * ch, color: [0, 0, 0])

    img =
      for col <- 0..(cols - 1), row <- 0..(rows - 1), reduce: base do
        acc ->
          cell = Image.new!(cw, ch, color: cell_color(col, row))
          Image.compose!(acc, cell, x: col * cw, y: row * ch)
      end

    path = Path.join(@config.out_dir, "grid.png")
    Image.write!(img, path)
    IO.puts("wrote #{path}  (#{cols}x#{rows} cells, #{cw}x#{ch} px each)")
    IO.puts("upload it to your TwicPics origin, then set TWIC_BASE to its URL.")
  end

  # ---- run + decode -------------------------------------------------------
  def run do
    File.mkdir_p!(@config.out_dir)
    IO.puts(String.pad_trailing("case", 32) <> "focus  expect  got       chain")
    IO.puts(String.duplicate("-", 96))
    Enum.each(@cases, &probe/1)
  end

  defp probe(c) do
    url = url_for(c)

    result =
      case Req.get(url, decode_body: false, retry: false) do
        {:ok, %{status: 200, body: body}} -> classify(body, c)
        {:ok, %{status: s}} -> {:http, s}
        {:error, e} -> {:error, Exception.message(e)}
      end

    report(c, result, url)
  end

  # Decode the centre pixel of the returned image into a cell (or padding).
  defp classify(body, c) do
    save_body(c, body)
    img = Image.from_binary!(body)
    {w, h} = {Image.width(img), Image.height(img)}
    px = Image.get_pixel!(img, div(w, 2), div(h, 2)) |> Enum.map(&round/1)

    cond do
      length(px) == 4 and List.last(px) < 16 -> {:padding, px, {w, h}}
      true -> {:cell, nearest_cell(Enum.take(px, 3)), px, {w, h}}
    end
  end

  # ---- url building -------------------------------------------------------
  defp url_for(%{chain: chain}), do: wrap("#{chain}/#{@config.suffix}")

  defp url_for(%{op: op, target: {col, row}}) do
    {cw, ch} = @config.cell
    {fcw, fch} = @config.final_crop
    fx = col * cw + div(cw, 2)
    fy = row * ch + div(ch, 2)

    ["focus=#{fx}x#{fy}", op, "crop=#{fcw}x#{fch}", @config.suffix]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("/")
    |> wrap()
  end

  # :query -> "<base>?twic=v1/<chain>" (usual). :path -> "<base>/v1/<chain>".
  defp wrap(chain) do
    if System.get_env("TWIC_API", "query") == "path",
      do: "#{@config.base}/v1/#{chain}",
      else: "#{@config.base}?twic=v1/#{chain}"
  end

  # ---- helpers ------------------------------------------------------------
  defp cell_color(col, row) do
    {cols, rows} = @config.grid
    [channel(col, cols), channel(row, rows), 255]
  end

  defp channel(_i, 1), do: 0
  defp channel(i, n), do: round(i * 255 / (n - 1))

  defp nearest_cell([r, g, b]) do
    {cols, rows} = @config.grid

    for(col <- 0..(cols - 1), row <- 0..(rows - 1), do: {col, row})
    |> Enum.min_by(fn {col, row} ->
      [cr, cg, cb] = cell_color(col, row)
      (cr - r) ** 2 + (cg - g) ** 2 + (cb - b) ** 2
    end)
  end

  defp report(c, result, url) do
    focus =
      case Map.get(c, :target) do
        {col, row} -> "#{col},#{row}"
        nil -> "-"
      end

    got =
      case result do
        {:cell, cell, _px, _dims} -> inspect(cell)
        {:padding, _px, _dims} -> "PADDING"
        other -> inspect(other)
      end

    mark =
      case result do
        {:cell, cell, _, _} -> if(cell == c.expect, do: "ok ", else: "DIFF")
        _ -> "??? "
      end

    chain = url |> String.split("v1/", parts: 2) |> List.last()

    IO.puts(
      String.pad_trailing(c.name, 32) <>
        String.pad_trailing(focus, 7) <>
        String.pad_trailing("#{elem(c.expect, 0)},#{elem(c.expect, 1)}", 8) <>
        String.pad_trailing("#{mark} #{got}", 10) <> chain
    )
  end

  defp save_body(c, body) do
    name = c.name |> String.replace(~r/[^a-z0-9]+/i, "_")
    File.write!(Path.join(@config.out_dir, "#{name}.png"), body)
  end
end

TwicFocusProbe.main(System.argv())
