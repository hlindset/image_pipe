defmodule ImagePipe.Test.ResolvedPlanCases do
  @moduledoc """
  Case matrix + recorder harness for the ResolvedPlan golden.

  Each case is a real imgproxy URL (parsed through the real imgproxy parser — no
  hand-built plan structs) over a committed differential source image. The
  recorder decodes the source exactly like a live request
  (`Request.Processor.decode_validate_source_response/3`, including
  shrink-on-load), attaches a uniquely-prefixed telemetry handler to
  `[:transform, :operation]` and `[:transform, :materialize]`, runs
  `Transform.execute_plan/3`, and records the executed op sequence (full op
  structs) with each op's realized post-op dims plus every materialize barrier.

  `bake!/0` writes the recordings to `resolved_plan_expected.exs`. The committed
  recordings were baked from the pre-cutover pipeline
  (`OrientationScheduler`-driven `Executor`), so the golden test is a
  genuine cross-implementation net rather than a self-consistency pin. Re-bake
  only deliberately — from a checkout whose pipeline you intend to become the
  new reference.
  """

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Request.Processor
  alias ImagePipe.Source
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @sources_dir "test/support/image_pipe/test/imgproxy_differential/sources"
  @expected_path "test/support/image_pipe/test/resolved_plan_expected.exs"

  @doc "The golden case matrix: imgproxy option segments over committed sources."
  def cases do
    [
      # plain fit (also exercises shrink-on-load on the 8x downscale)
      %{name: :plain_fit, source: "high_freq.jpg", opts: "rs:fit:200:150"},
      # cover + result-crop (always fires on fill)
      %{name: :cover_result_crop, source: "high_freq.jpg", opts: "rs:fill:240:180/g:no"},
      # auto: landscape source x landscape target -> cover
      %{name: :auto_landscape_cover, source: "high_freq.jpg", opts: "rs:auto:300:200"},
      # auto: landscape source x portrait target -> fit
      %{name: :auto_portrait_fit, source: "high_freq.jpg", opts: "rs:auto:200:300"},
      # min-dimension coupling past the box (#236/#194): scale 373x280, crop 300x280
      %{name: :min_width_coupling, source: "high_freq.jpg", opts: "rs:fit:300:300/mw:280/mh:280"},
      # no-enlarge dpr cap with no geometry (#237): padding stays unscaled
      %{name: :dpr_cap_no_geometry, source: "small.png", opts: "pd:10:4:2:8/dpr:2"},
      # quarter-turn cover resolved in the display frame (#182), trailing flush
      %{name: :quarter_turn_cover, source: "exif_6.jpg", opts: "rs:fill:60:80"},
      # shrink-on-load rescaled crop before the residual resize (#151)
      %{
        name: :shrink_crop_resize,
        source: "high_freq.jpg",
        opts: "c:800:600:nowe/rs:fit:100:100"
      },
      # trim under a pending quarter turn: storage-frame trim, pending kept
      %{name: :trim_pending_quarter_turn, source: "exif_6.jpg", opts: "t:10"},
      # fill-down with target > source: asymmetric aspect-ratio result crop
      %{name: :fill_down_target_gt_source, source: "small.png", opts: "rs:fill-down:600:400"},
      # trim -> resize -> padding: ctx padding scales survive intervening measures
      %{
        name: :trim_resize_padding,
        source: "border_asym.png",
        opts: "t:10/rs:fit:400:300/pd:12:12:12:12"
      },
      # identity-pending streaming: effects only, no flush, materialized? stays false
      %{name: :identity_streaming, source: "high_freq.jpg", opts: "bl:2"}
    ]
  end

  @doc "The imgproxy request path for a case."
  def imgproxy_path(%{opts: opts, source: source}),
    do: "/unsafe/#{opts}/plain/local:///#{source}"

  @doc "Parse a case's URL through the real imgproxy parser into a Plan."
  def parse_plan!(%{} = kase) do
    conn = Plug.Test.conn(:get, imgproxy_path(kase))
    {:ok, plan} = Imgproxy.parse(conn, [])
    plan
  end

  @doc """
  Decode a case's source the way a live request does (shrink-on-load included)
  and return the pre-transform seed facts plus the initial `State`.
  """
  def decode!(%{} = kase, plan) do
    response = %Source.Response{path: Path.join(@sources_dir, kase.source)}

    {:ok, decoded} =
      Processor.decode_validate_source_response(response, plan, max_input_pixels: 40_000_000)

    source_dimensions = Map.get(decoded, :source_dimensions)
    decode_shrink = if source_dimensions, do: Map.get(decoded, :achieved_shrink)

    state = %State{
      image: decoded.image,
      source_dimensions: source_dimensions,
      decode_shrink: decode_shrink
    }

    seed = %{
      original_dims: decoded.original_dims,
      decoded_dims: {VipsImage.width(decoded.image), VipsImage.height(decoded.image)},
      source_dimensions: source_dimensions,
      decode_shrink: decode_shrink,
      exif_orientation: exif_orientation(decoded.image)
    }

    {seed, state}
  end

  @doc """
  Run a case through `Transform.execute_plan/3` and record the executed op /
  materialize event sequence plus the final state facts.

  Events (in emission order):

    * `{:op_start, name, index, params}` / `{:op_stop, name, index, dims, result}`
    * `{:materialize_start}` / `{:materialize_stop, dims, result}`

  A materialize pair between an op's `:op_start` and `:op_stop` is that op's
  own (nested) materialization; a standalone pair is a scheduler/boundary flush.
  """
  def record!(%{name: name} = kase) do
    plan = parse_plan!(kase)
    {seed, state} = decode!(kase, plan)

    prefix = [:resolved_plan_recorder, :"#{name}_#{System.unique_integer([:positive])}"]
    {:ok, agent} = Agent.start_link(fn -> [] end)
    handler_id = {__MODULE__, name, agent}

    events =
      for stage <- [[:transform, :operation], [:transform, :materialize]],
          suffix <- [:start, :stop],
          do: prefix ++ stage ++ [suffix]

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, agent)

    try do
      {:ok, %State{} = final} =
        ImagePipe.Transform.execute_plan(plan, state,
          seed_orientation: true,
          telemetry_prefix: prefix
        )

      %{
        name: name,
        path: imgproxy_path(kase),
        source: kase.source,
        opts: kase.opts,
        auto_rotate: plan.auto_rotate,
        seed: seed,
        events: Agent.get(agent, &Enum.reverse/1),
        final_dims: {VipsImage.width(final.image), VipsImage.height(final.image)},
        final_materialized: final.materialized?
      }
    after
      :telemetry.detach(handler_id)
      Agent.stop(agent)
    end
  end

  @doc false
  def handle_event(event, _measurements, metadata, agent) do
    entry =
      case Enum.take(event, -2) do
        [:operation, :start] ->
          {:op_start, metadata.operation, metadata.index, metadata.params}

        [:operation, :stop] ->
          {:op_stop, metadata.operation, metadata.index, Map.get(metadata, :dims),
           metadata.result}

        [:materialize, :start] ->
          {:materialize_start}

        [:materialize, :stop] ->
          {:materialize_stop, Map.get(metadata, :dims), metadata.result}
      end

    Agent.update(agent, &[entry | &1])
  end

  @doc "Record every case and write the expected data file."
  def bake! do
    recordings = Enum.map(cases(), &record!/1)

    header = """
    # Baked by ImagePipe.Test.ResolvedPlanCases.bake!/0 — the executed op /
    # materialize sequence and realized per-op dims of the PRE-cutover pipeline
    # (OrientationScheduler-driven Executor), recorded as the golden
    # `expected` data for the ResolvedPlan golden test. Do not edit by hand.
    """

    body = inspect(recordings, limit: :infinity, printable_limit: :infinity, pretty: true)
    File.write!(@expected_path, header <> body <> "\n")
    :ok
  end

  @doc "Read the committed expected recordings."
  def expected do
    {recordings, _bindings} = Code.eval_file(@expected_path)
    recordings
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) -> value
      _ -> 1
    end
  end
end
