defmodule ImagePipe.SVGTest do
  use ExUnit.Case, async: true

  alias ImagePipe.SVG
  alias ImagePipe.SVG.Document

  @font_dir Path.expand("../support/fonts", __DIR__)

  setup_all do
    {:ok, fonts} = SVG.load_fonts([@font_dir], fallback_family: "Geist Mono")
    {:ok, no_fallback} = SVG.load_fonts([@font_dir])
    {:ok, fonts: fonts, no_fallback: no_fallback}
  end

  defp svg(body, attrs \\ ~s(width="10" height="10")) do
    ~s(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" #{attrs}>#{body}</svg>)
  end

  defp render!(source, fonts, width, height) do
    {:ok, document} = SVG.parse(source, fonts)
    {:ok, rgba} = SVG.render(document, width, height)
    rgba
  end

  defp pixel(rgba, width, x, y) do
    offset = (y * width + x) * 4
    <<_::binary-size(^offset), r, g, b, a, _::binary>> = rgba
    [r, g, b, a]
  end

  defp transparent?(rgba), do: rgba == :binary.copy(<<0>>, byte_size(rgba))

  # A solid-colour PNG, built by hand so the tests need no image library.
  defp png(width, height, [r, g, b]) do
    row = <<0>> <> :binary.copy(<<r, g, b>>, width)
    data = :zlib.compress(:binary.copy(row, height))
    header = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<137, "PNG", 13, 10, 26, 10>> <>
      chunk("IHDR", header) <> chunk("IDAT", data) <> chunk("IEND", "")
  end

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  defp data_uri(mime, data), do: "data:#{mime};base64,#{Base.encode64(data)}"

  test "reports the NIF version and the resvg version from Cargo.lock" do
    lock = File.read!("native/image_pipe_svg_nif/Cargo.lock")
    [_, resvg] = Regex.run(~r/name = "resvg"\nversion = "([^"]+)"/, lock)

    assert %{nif: nif, resvg: ^resvg, render: render} = SVG.versions()
    assert nif == Mix.Project.config()[:version]
    assert is_integer(render)
  end

  describe "load_fonts/2" do
    test "fingerprints the font files", %{fonts: fonts} do
      assert fonts.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, %{fingerprint: same}} = SVG.load_fonts([@font_dir])
      assert same == fonts.fingerprint
    end

    @tag :tmp_dir
    test "a renamed or added font changes the fingerprint", %{tmp_dir: dir, fonts: fonts} do
      File.cp!(Path.join(@font_dir, "GeistMono-Regular.ttf"), Path.join(dir, "Other.ttf"))
      assert {:ok, renamed} = SVG.load_fonts([dir])
      refute renamed.fingerprint == fonts.fingerprint

      File.mkdir_p!(Path.join(dir, "nested"))
      File.cp!(Path.join(@font_dir, "GeistMono-Regular.ttf"), Path.join(dir, "nested/Again.otf"))
      assert {:ok, added} = SVG.load_fonts([dir])
      refute added.fingerprint == renamed.fingerprint
    end

    @tag :tmp_dir
    test "fails on a file that isn't a font", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "Broken.ttf"), "not a font")
      assert {:error, message} = SVG.load_fonts([dir])
      assert message =~ "Broken.ttf"
    end

    @tag :tmp_dir
    test "fails on a directory that doesn't exist", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing")
      assert {:error, message} = SVG.load_fonts([missing])
      assert message =~ missing
    end

    test "fails on a fallback family that isn't loaded" do
      assert {:error, message} = SVG.load_fonts([@font_dir], fallback_family: "Comic Sans MS")
      assert message =~ "Comic Sans MS"
    end
  end

  describe "parse/3" do
    test "reads the intrinsic size at 96 DPI", %{fonts: fonts} do
      assert {:ok, %Document{width: 96.0, height: 48.0}} =
               SVG.parse(svg("", ~s(width="1in" height="12.7mm")), fonts)

      assert {:ok, %Document{width: 40.0, height: 20.0}} =
               SVG.parse(svg("", ~s(viewBox="0 0 40 20")), fonts)
    end

    test "sizes an SVG with no size and no viewBox to its content", %{fonts: fonts} do
      content = ~s(<rect x="250" y="100" width="50" height="50" fill="#ff0000"/>)
      assert {:ok, %Document{width: 300.0, height: 150.0}} = SVG.parse(svg(content, ""), fonts)
    end

    test "fails on malformed XML and entity loops", %{fonts: fonts} do
      assert {:error, {:parse, _}} = SVG.parse("<svg", fonts)

      loop = ~s(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "&b;"><!ENTITY b "&a;">]>)
      assert {:error, {:entity_expansion, _}} = SVG.parse(loop <> svg("<text>&a;</text>"), fonts)
    end

    test "fails before expanding entities past the limit", %{fonts: fonts} do
      # 250 references of 2,000 characters each per &y;: about 5 MB from 20.
      x = String.duplicate("a", 2000)
      y = String.duplicate("&x;", 250)
      doctype = ~s(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x "#{x}"><!ENTITY y "#{y}">]>)
      # In an attribute, so the accepted parse doesn't lay out megabytes of text.
      bomb = doctype <> svg(~s(<rect id="#{String.duplicate("&y;", 10)}" width="1" height="1"/>))

      assert {:error, {:entity_expansion, expanded}} = SVG.parse(bomb, fonts)
      assert expanded >= 5_000_000
      assert {:ok, _} = SVG.parse(bomb, fonts, max_entity_expansion: 6_000_000)

      # Editors declare small entities, such as namespace URIs.
      small = ~s(<!DOCTYPE svg [<!ENTITY ns "http://www.w3.org/2000/svg">]>)
      assert {:ok, _} = SVG.parse(small <> svg("<text>&ns;</text>"), fonts)
    end

    test "finds entity bombs whatever surrounds their declarations", %{fonts: fonts} do
      x = String.duplicate("a", 2000)
      y = String.duplicate("&x;", 250)
      entities = ~s(<!ENTITY x "#{x}"><!ENTITY y "#{y}">)
      body = svg(~s(<rect id="#{String.duplicate("&y;", 10)}" width="1" height="1"/>))

      for doctype <- [
            # A decoy DOCTYPE in a comment before the real one.
            ~s(<!-- <!DOCTYPE x> --><!DOCTYPE svg [#{entities}]>),
            # A `>` in the external identifier.
            ~s(<!DOCTYPE svg SYSTEM "a>b" [#{entities}]>),
            # A stray quote in a processing instruction in the subset.
            ~s(<!DOCTYPE svg [<?pi ' ?>#{entities}]>),
            # A smaller decoy declaration of the same name in a comment.
            ~s(<!DOCTYPE svg [<!-- <!ENTITY y "z"> -->#{entities}]>)
          ] do
        assert {:error, {:entity_expansion, _}} = SVG.parse(doctype <> body, fonts)
      end
    end

    test "limits elements and text across all embedded SVGs together", %{fonts: fonts} do
      rects = String.duplicate(~s(<rect width="1" height="1"/>), 100)
      inner = data_uri("image/svg+xml", svg(rects))
      image = ~s(<image id="i" width="10" height="10" href="#{inner}"/>)
      copies = String.duplicate(~s(<use href="#i"/>), 20)

      # Each copy alone is within the limit, all of them together aren't.
      assert {:ok, _} = SVG.parse(svg(image), fonts, max_elements: 1_000)

      assert {:error, {:too_many_elements, _}} =
               SVG.parse(svg(image <> copies), fonts, max_elements: 1_000)

      text = data_uri("image/svg+xml", svg("<text>" <> String.duplicate("a", 100) <> "</text>"))
      images = String.duplicate(~s(<image width="10" height="10" href="#{text}"/>), 20)
      assert {:error, {:too_much_text, _}} = SVG.parse(svg(images), fonts, max_text: 1_000)
    end

    test "fails before parsing elements nested too deep", %{fonts: fonts} do
      deep = String.duplicate("<g>", 150_000) <> String.duplicate("</g>", 150_000)
      assert {:error, {:parse, _}} = SVG.parse(svg(deep), fonts)

      # Entities could nest markup past the scan, so markup in them is refused.
      markup = ~s(<!DOCTYPE svg [<!ENTITY g "<g/>">]>)
      assert {:error, {:parse, _}} = SVG.parse(markup <> svg("&g;"), fonts)
    end

    test "fails on a long chain of entities without overflowing", %{fonts: fonts} do
      chain = Enum.map_join(0..299_999, &~s(<!ENTITY e#{&1} "&e#{&1 + 1};">))
      doctype = ~s(<!DOCTYPE svg [#{chain}<!ENTITY e300000 "a">]>)

      assert {:error, {:entity_expansion, _}} =
               SVG.parse(doctype <> svg("<text>&e0;</text>"), fonts)
    end

    test "scans many ampersands in linear time", %{fonts: fonts} do
      doctype = ~s(<!DOCTYPE svg [<!ENTITY a "b">]>)
      body = svg("<!-- " <> String.duplicate("&", 1_000_000) <> " -->")

      {microseconds, {:ok, _}} = :timer.tc(fn -> SVG.parse(doctype <> body, fonts) end)
      assert microseconds < 5_000_000
    end

    test "fails on an unclosed entity value instead of panicking", %{fonts: fonts} do
      assert {:error, {:parse, _}} = SVG.parse(~s(<!-- <!ENTITY a "é), fonts)
    end

    test "counts what markers, bounding-box clip paths and filter images copy", %{fonts: fonts} do
      opts = [max_elements: 1_000]
      rects = &String.duplicate(~s[<rect width="1" height="1" #{&1}/>], 100)
      shapes = String.duplicate(~s(<rect width="1" height="1"/>), 20)

      marker = ~s(<marker id="m">#{shapes}</marker>)
      points = Enum.map_join(1..100, " ", &"#{&1},#{&1}")
      path = ~s[<polyline marker-mid="url(#m)" points="#{points}"/>]
      assert {:error, {:too_many_elements, _}} = SVG.parse(svg(marker <> path), fonts, opts)

      clip = ~s(<clipPath id="c" clipPathUnits="objectBoundingBox">#{shapes}</clipPath>)
      clipped = rects.(~s[clip-path="url(#c)"])
      assert {:error, {:too_many_elements, _}} = SVG.parse(svg(clip <> clipped), fonts, opts)

      # Shared in user space, so not copied per use.
      shared = ~s(<clipPath id="c">#{shapes}</clipPath>)
      assert {:ok, _} = SVG.parse(svg(shared <> clipped), fonts, opts)

      # A mask's region is the user's bounding box by default, so each user
      # gets its own copy whatever its content units.
      mask = ~s(<mask id="k">#{shapes}</mask>)
      masked = rects.(~s[mask="url(#k)"])
      assert {:error, {:too_many_elements, _}} = SVG.parse(svg(mask <> masked), fonts, opts)

      # Ids aren't unique in every document, so another element with the
      # clip path's id must not hide its copies.
      duplicate = clip <> clipped <> ~s(<svg xmlns="urn:other"><path id="c"/></svg>)
      assert {:error, {:too_many_elements, _}} = SVG.parse(svg(duplicate), fonts, opts)

      filter = ~s(<g id="s">#{shapes}</g><filter id="f"><feImage href="#s"/></filter>)
      filtered = rects.(~s[filter="url(#f)"])
      assert {:error, {:too_many_elements, _}} = SVG.parse(svg(filter <> filtered), fonts, opts)
    end

    test "fails on numbers too large to compute with", %{fonts: fonts} do
      # The fuzzer's input: usvg spent seconds and gigabytes converting it.
      arc = ~s(<svg><path d="M1 9A1 1013333333333333333333333333333 7,119,1 "/></svg>)
      assert {:error, {:parse, _}} = SVG.parse(arc, fonts)

      assert {:error, {:parse, _}} =
               SVG.parse(svg(~s(<rect width="1" height="1" stroke-width="2e16"/>)), fonts)

      styled = svg(~s(<style>.a{stroke-width:1e30}</style><rect class="a" width="1" height="1"/>))
      assert {:error, {:parse, _}} = SVG.parse(styled, fonts)

      assert {:ok, _} = SVG.parse(svg(~s(<rect id="a1e99" width="1e9" height="1"/>)), fonts)
    end

    test "fails on elements that reference each other in a cycle", %{fonts: fonts} do
      # usvg follows this cycle until the stack overflows, which would end the VM.
      cycle =
        ~s(<filter id="f"><feImage href="#b"/></filter><filter id="h"><feImage href="#a"/></filter>) <>
          ~s[<g id="a" filter="url(#f)"><rect width="8" height="8"/></g>] <>
          ~s[<g id="b" filter="url(#h)"><rect width="8" height="8"/></g>]

      assert {:error, {:parse, _}} = SVG.parse(svg(cycle), fonts)

      use_cycle = ~s(<g id="a"><use href="#b"/></g><g id="b"><use href="#a"/></g>)
      assert {:error, {:parse, _}} = SVG.parse(svg(use_cycle), fonts)
    end

    test "fails on a reference chain deeper than the stack allows", %{fonts: fonts} do
      chain = fn length ->
        Enum.map_join(0..(length - 1), fn i ->
          ~s[<filter id="f#{i}"><feImage href="#g#{i + 1}"/></filter>] <>
            ~s[<g id="g#{i}" filter="url(#f#{i})"><rect width="1" height="1"/></g>]
        end) <> ~s(<g id="g#{length}"/>)
      end

      assert {:error, {:parse, _}} =
               SVG.parse(svg(chain.(3_000)), fonts, max_elements: 10_000_000)
    end

    test "counts the outer document and embedded SVGs against the same limits", %{fonts: fonts} do
      rects = String.duplicate(~s(<rect width="1" height="1"/>), 600)
      inner = data_uri("image/svg+xml", svg(rects))
      image = ~s(<image width="10" height="10" href="#{inner}"/>)

      assert {:ok, _} = SVG.parse(svg(image), fonts, max_elements: 1_000)

      assert {:error, {:too_many_elements, _}} =
               SVG.parse(svg(rects <> image), fonts, max_elements: 1_000)
    end

    test "checks embedded SVGs for entity bombs too", %{fonts: fonts} do
      x = String.duplicate("a", 2000)
      y = String.duplicate("&x;", 250)
      doctype = ~s(<!DOCTYPE svg [<!ENTITY x "#{x}"><!ENTITY y "#{y}">]>)
      inner = doctype <> svg("<text>" <> String.duplicate("&y;", 10) <> "</text>")
      image = ~s(<image width="10" height="10" href="#{data_uri("image/svg+xml", inner)}"/>)

      assert {:error, {:entity_expansion, _}} = SVG.parse(svg(image), fonts)
    end

    test "fails before laying out too much text in one element", %{fonts: fonts} do
      spans = String.duplicate("<tspan>" <> String.duplicate("abc ", 25) <> "</tspan>", 101)
      long = svg(~s(<text y="10">#{spans}</text>))

      assert {:error, {:too_much_text, 10_100}} = SVG.parse(long, fonts)
      assert {:ok, _} = SVG.parse(long, fonts, max_text_per_element: 10_100)
    end

    test "fails before laying out too much text in all", %{fonts: fonts} do
      label = ~s(<text y="10">) <> String.duplicate("a", 100) <> "</text>"
      # 50 labels, each drawn 300 times through <use>: 1,500,000 characters.
      labels =
        svg(
          ~s(<defs><g id="l">#{String.duplicate(label, 50)}</g></defs>) <>
            String.duplicate(~s(<use href="#l"/>), 300)
        )

      assert {:error, {:too_much_text, total}} = SVG.parse(labels, fonts)
      assert total >= 1_500_000
      assert {:ok, _} = SVG.parse(labels, fonts, max_text: 2_000_000)

      # Whitespace between elements isn't laid out, so it doesn't count.
      spaced = svg(String.duplicate(~s(<rect width="1" height="1"/>\n          ), 1000))
      assert {:ok, _} = SVG.parse(spaced, fonts, max_text: 10)
    end

    test "counts stroked curves by their length", %{fonts: fonts} do
      # Smooth quadratic curves that swing 10,000 pixels each way. Stroking
      # them takes seconds though they cover little of the canvas.
      d = "M0 0 Q5 10000 10 0" <> String.duplicate(" T 20 0 T 30 0", 500)

      work = fn paint ->
        {:ok, document} = SVG.parse(svg(~s(<path d="#{d}" #{paint}/>)), fonts)
        SVG.cost(document, 64, 64).work
      end

      assert work.(~s(stroke="#000" fill="none")) > 100_000_000
      assert work.(~s(fill="#000")) < 100_000_000
    end

    test "counts each clip path's paths once per use", %{fonts: fonts} do
      cost = fn paths ->
        clip =
          ~s(<clipPath id="c">) <>
            String.duplicate(~s(<rect width="5" height="5"/>), paths) <> "</clipPath>"

        groups =
          String.duplicate(~s[<g clip-path="url(#c)"><rect width="10" height="10"/></g>], 100)

        {:ok, document} = SVG.parse(svg(clip <> groups), fonts)
        SVG.cost(document, 10, 10).work
      end

      # 100 groups × 999 more clip paths × at least 200 units per path.
      assert cost.(1_000) - cost.(1) >= 100 * 999 * 200
    end

    test "fails before expanding a <use> bomb", %{fonts: fonts} do
      levels =
        for level <- 1..5 do
          ~s(<g id="g#{level}">) <>
            String.duplicate(~s(<use href="#g#{level - 1}"/>), 10) <> "</g>"
        end

      source =
        svg(~s(<defs><rect id="g0" width="1" height="1"/>#{levels}</defs><use href="#g5"/>))

      assert {:error, {:too_many_elements, count}} = SVG.parse(source, fonts)
      assert count > 200_000
      assert {:ok, _} = SVG.parse(source, fonts, max_elements: 1_000_000)
    end
  end

  # usvg allows 1024 levels; each level recurses in parsing, the cost walk,
  # and rendering, which overflowed a dirty scheduler's stack and took the VM
  # down at a few hundred levels.
  test "handles nesting as deep as usvg allows", %{fonts: fonts} do
    depth = 1000

    source =
      svg(
        String.duplicate(~s(<g opacity="0.99">), depth) <>
          ~s(<rect width="10" height="10" fill="#ff0000"/>) <> String.duplicate("</g>", depth)
      )

    {:ok, document} = SVG.parse(source, fonts)
    assert %{peak: peak} = SVG.cost(document, 10, 10)
    assert peak > depth * 100
    assert {:ok, rgba} = SVG.render(document, 10, 10)
    assert [255, 0, 0, _] = pixel(rgba, 10, 5, 5)
  end

  describe "render/3" do
    test "refuses geometry far past the canvas, which would overflow", %{fonts: fonts} do
      # The fuzzer's input: tiny-skia aborted the VM drawing this curve.
      far = ~s(<svg width="8" height="4"><path d="M4,0S4,578888888 6,0 6 3,6 9"/></svg>)
      {:ok, document} = SVG.parse(far, fonts)
      assert {:error, {:out_of_range, extent}} = SVG.render(document, 8, 4)
      assert extent > 500_000_000

      near = svg(~s(<rect x="-30000" width="30010" height="10"/>))
      {:ok, document} = SVG.parse(near, fonts)
      assert {:ok, _rgba} = SVG.render(document, 10, 10)
    end

    test "renders at the requested size", %{fonts: fonts} do
      rgba = render!(svg(~s(<rect width="5" height="10" fill="#ff0000"/>)), fonts, 40, 40)

      assert byte_size(rgba) == 40 * 40 * 4
      assert pixel(rgba, 40, 5, 20) == [255, 0, 0, 255]
      assert pixel(rgba, 40, 30, 20) == [0, 0, 0, 0]
    end

    test "scales each axis to the requested size", %{fonts: fonts} do
      rgba = render!(svg(~s(<rect width="5" height="5" fill="#00ff00"/>)), fonts, 40, 20)

      assert pixel(rgba, 40, 15, 5) == [0, 255, 0, 255]
      assert pixel(rgba, 40, 25, 5) == [0, 0, 0, 0]
      assert pixel(rgba, 40, 15, 15) == [0, 0, 0, 0]
    end

    test "returns straight alpha", %{fonts: fonts} do
      rgba =
        render!(
          svg(~s(<rect width="10" height="10" fill="#ff8000" fill-opacity="0.5"/>)),
          fonts,
          4,
          4
        )

      assert [255, 128, 0, alpha] = pixel(rgba, 4, 1, 1)
      assert alpha in 127..128
    end

    test "renders text in a loaded family", %{no_fallback: fonts} do
      text = ~s(<text x="0" y="40" font-family="Geist Mono" font-size="40">M</text>)
      refute transparent?(render!(svg(text, ~s(width="50" height="50")), fonts, 50, 50))
    end

    test "renders a missing family in the fallback family", %{
      fonts: fonts,
      no_fallback: no_fallback
    } do
      text = ~s(<text x="0" y="40" font-family="Nope, sans-serif" font-size="40">M</text>)
      source = svg(text, ~s(width="50" height="50"))

      refute transparent?(render!(source, fonts, 50, 50))
      assert transparent?(render!(source, no_fallback, 50, 50))
    end
  end

  describe "untrusted references" do
    @tag :tmp_dir
    test "never reads files or fetches URLs", %{tmp_dir: dir, fonts: fonts} do
      canary = Path.join(dir, "canary.png")
      File.write!(canary, png(4, 4, [255, 0, 0]))

      red = <<255, 0, 0, 255>>

      for href <- [canary, "file://#{canary}", "canary.png", "http://127.0.0.1:1/x.png"] do
        image = ~s(<image width="10" height="10" href="#{href}"/>)
        assert transparent?(render!(svg(image), fonts, 10, 10)), "rendered #{href}"

        css = ~s[<style>rect { fill: url('#{href}') }</style><rect width="10" height="10"/>]

        assert :binary.match(render!(svg(css), fonts, 10, 10), red) == :nomatch,
               "drew the canary from url(#{href})"
      end
    end
  end

  describe "embedded images" do
    test "render when the media type matches the contents", %{fonts: fonts} do
      image =
        ~s(<image width="10" height="10" href="#{data_uri("image/png", png(4, 4, [0, 0, 255]))}"/>)

      assert pixel(render!(svg(image), fonts, 10, 10), 10, 5, 5) == [0, 0, 255, 255]
    end

    test "render as empty with a mismatched media type", %{fonts: fonts} do
      image =
        ~s(<image width="10" height="10" href="#{data_uri("image/jpeg", png(4, 4, [0, 0, 255]))}"/>)

      assert transparent?(render!(svg(image), fonts, 10, 10))
    end

    test "render as empty when gzip-compressed", %{fonts: fonts} do
      inner = :zlib.gzip(svg(~s(<rect width="10" height="10" fill="red"/>)))
      image = ~s(<image width="10" height="10" href="#{data_uri("image/svg+xml", inner)}"/>)
      assert transparent?(render!(svg(image), fonts, 10, 10))
    end

    test "fail when larger than the per-image limit", %{fonts: fonts} do
      image =
        ~s(<image width="10" height="10" href="#{data_uri("image/png", png(20, 10, [0, 0, 255]))}"/>)

      assert {:error, {:image_too_large, 200}} =
               SVG.parse(svg(image), fonts, max_image_pixels: 199)

      assert {:ok, _} = SVG.parse(svg(image), fonts, max_image_pixels: 200)
    end

    test "nest at most two levels deep", %{fonts: fonts} do
      nest = fn source ->
        svg(~s(<image width="10" height="10" href="#{data_uri("image/svg+xml", source)}"/>))
      end

      leaf = svg(~s(<rect width="10" height="10" fill="#ff0000"/>))
      two = leaf |> nest.() |> nest.()

      assert pixel(render!(two, fonts, 10, 10), 10, 5, 5) == [255, 0, 0, 255]
      assert {:error, :nesting_too_deep} = SVG.parse(nest.(two), fonts)
    end
  end

  describe "cost/3" do
    test "counts each draw of an image referenced by <use>", %{fonts: fonts} do
      image = data_uri("image/png", png(100, 100, [0, 0, 255]))

      source =
        svg(
          ~s(<defs><image id="i" width="10" height="10" href="#{image}"/></defs>) <>
            String.duplicate(~s(<use href="#i"/>), 50)
        )

      {:ok, document} = SVG.parse(source, fonts)
      assert %{images: 50, image_pixels: 500_000} = SVG.cost(document, 10, 10)
    end

    test "grows with the render size", %{fonts: fonts} do
      blur =
        svg(
          ~s(<filter id="f"><feGaussianBlur stdDeviation="2"/></filter>) <>
            ~s[<rect width="10" height="10" filter="url(#f)"/>]
        )

      {:ok, document} = SVG.parse(blur, fonts)
      small = SVG.cost(document, 100, 100)
      large = SVG.cost(document, 1000, 1000)

      assert large.work > 50 * small.work
      assert large.peak > 50 * small.peak
    end

    test "counts layers alive at once for nested groups", %{fonts: fonts} do
      nested = fn depth ->
        String.duplicate(~s(<g opacity="0.9">), depth) <>
          ~s(<rect width="10" height="10"/>) <> String.duplicate("</g>", depth)
      end

      {:ok, shallow} = SVG.parse(svg(nested.(2)), fonts)
      {:ok, deep} = SVG.parse(svg(nested.(50)), fonts)

      assert SVG.cost(deep, 100, 100).peak > 10 * SVG.cost(shallow, 100, 100).peak
    end

    test "weights morphology by its kernel at the render scale", %{fonts: fonts} do
      dilate =
        svg(
          ~s(<filter id="f"><feMorphology operator="dilate" radius="2"/></filter>) <>
            ~s[<rect width="10" height="10" filter="url(#f)"/>]
        )

      {:ok, document} = SVG.parse(dilate, fonts)
      # 10× the size gives 100× the pixels and a kernel 10× wider and taller.
      assert SVG.cost(document, 100, 100).work > 1_000 * SVG.cost(document, 10, 10).work
    end
  end
end
