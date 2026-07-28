defmodule ImagePipe.ShrinkOnLoadPropertyTest do
  # Real image encode/decode per case — keep it serial and bound the runs.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.State

  # Shrink-on-load decodes a JPEG at reduced resolution, then a residual resize
  # finishes to the requested width. Because the decode prescale is a single scalar
  # derived from the *width* ratio, the reconstructed source height (and the auto
  # output height) can drift slightly for sources that don't divide cleanly by the
  # shrink factor.
  #
  # The honest contract is *not* "output equals the requested pixels" — the residual
  # resize scales by a fractional factor, so even the full-decode path can land ±1px
  # off a requested dimension. The contract is that shrink-on-load does not move the
  # output away from the *full-decode* result by more than ±1px on either axis. That
  # ±1 is the residual-resize's own scale-rounding floor (the full-decode path has it
  # too); it holds only because the residual resize sizes against the *exact* stored
  # original dims, not dims reconstructed from the shrunk image.
  #
  # We get the full-decode baseline by running the identical pipeline on the same
  # source encoded as PNG (not shrink-eligible, so it decodes full-resolution). Any
  # difference is therefore attributable to shrink-on-load alone. If this ever fails,
  # the message prints the case so the real bound can be re-pinned, not silently
  # widened.
  property "shrink-on-load output stays within ±1px of the full-decode path on both axes" do
    check all(
            # Cover width-only, height-only, and square fit targets so the drift is
            # exercised with the height as the *driving* axis too, not just as a
            # consequence of a width-only request.
            mode <- member_of([:width, :height, :square]),
            source_w <- integer(1200..3600),
            source_h <- integer(1200..3600),
            # target ≤ governing_dim / 4 guarantees load_shrink ≥ ~4, so JPEG shrink
            # (4 or 8) actually fires — the case is never a vacuous no-shrink one.
            target <- integer(60..div(governing_dim(mode, source_w, source_h), 4)),
            max_runs: 100
          ) do
      resize = fit_resize(mode, target)

      {shrink_w, shrink_h, shrink} =
        decode_resize(solid(source_w, source_h, ".jpg"), resize)

      {full_w, full_h, no_shrink} =
        decode_resize(solid(source_w, source_h, ".png"), resize)

      label = "#{source_w}x#{source_h} #{mode}:#{target}"

      assert shrink in [2, 4, 8],
             "expected JPEG shrink to fire for #{label}, got #{inspect(shrink)}"

      assert no_shrink == nil,
             "PNG baseline must not shrink for #{label}, got #{inspect(no_shrink)}"

      assert abs(shrink_w - full_w) <= 1 and abs(shrink_h - full_h) <= 1,
             "shrink-on-load #{shrink_w}x#{shrink_h} drifted >1px from full-decode " <>
               "#{full_w}x#{full_h} for #{label} (shrink #{shrink})"
    end
  end

  # The axis that determines the shrink factor (so the target keeps it ≥ ~4).
  defp governing_dim(:width, source_w, _source_h), do: source_w
  defp governing_dim(:height, _source_w, source_h), do: source_h
  defp governing_dim(:square, source_w, source_h), do: min(source_w, source_h)

  defp fit_resize(:width, target), do: build_fit({:px, target}, :auto)
  defp fit_resize(:height, target), do: build_fit(:auto, {:px, target})
  defp fit_resize(:square, target), do: build_fit({:px, target}, {:px, target})

  defp build_fit(width, height) do
    {:ok, resize} = Operation.resize(:fit, width, height)
    resize
  end

  defp solid(width, height, suffix) do
    {:ok, image} = Image.new(width, height, color: [120, 130, 140])
    Image.write!(image, :memory, suffix: suffix)
  end

  defp decode_resize(body, resize) do
    plan = %Plan{
      source: %Path{segments: ["property.img"]},
      output: %{},
      pipelines: [%Pipeline{operations: [resize]}]
    }

    opts = opts(body)
    {:ok, source} = Source.resolve(plan.source, opts, [])

    Decode.with_image(
      source,
      Keyword.put(opts, :auto_rotate?, plan.auto_rotate),
      &Declarative.decode_request(plan, &1),
      fn state, geometry ->
        {:ok, %State{} = final} = Declarative.execute(state, geometry, plan, opts)

        {Image.width(final.image), Image.height(final.image), shrink_factor(state.decode_shrink)}
      end
    )
  end

  # The realized load shrink, rounded back to the libjpeg block factor the
  # planner asked for. `nil` when the decode was not shrunk at all.
  defp shrink_factor(nil), do: nil
  defp shrink_factor(%{w: w}), do: round(w)

  defp opts(body) do
    Source.validate_config!(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: origin_plug(body)]}
      ],
      max_input_pixels: 100_000_000,
      max_result_width: 100_000,
      max_result_height: 100_000,
      max_result_pixels: 1_000_000_000,
      max_body_bytes: 100_000_000
    )
  end

  defp origin_plug(body) do
    content_type =
      case body do
        <<0xFF, 0xD8, _rest::binary>> -> "image/jpeg"
        _other -> "image/png"
      end

    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(200, body)
    end
  end
end
