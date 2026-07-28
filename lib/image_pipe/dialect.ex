defmodule ImagePipe.Dialect do
  @moduledoc """
  The coarse request-lifecycle contract a dialect implements to mount through
  `ImagePipe.Plug` (`plug ImagePipe.Plug, dialect: __MODULE__, <flat config>`).

  Six required callbacks — one per lifecycle phase, never a mid-execution
  hook. Everything else a dialect decides rides `ImagePipe.Dialect.Resolved`
  as values.

  ## The anti-leak rule (design decision U4)

  The runner in `ImagePipe.Plug` branches only on `Resolved` fields and
  neutral core structs. It never names a dialect and never accepts a
  dialect-specific option. A future need that cannot be expressed as a new
  `Resolved` value with a sensible default belongs in the dialect, not the
  runner.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Source,
      ImagePipe.Transform
    ],
    exports: [DebugContext, Failure, Negotiation, RenderTerminal, Resolved]

  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  @type config :: keyword()
  @type request :: term()
  @type parse_result ::
          {:ok, request()}
          | {:redirect, pos_integer(), String.t()}
          | {:error, term()}

  @doc """
  Init-time config validation; raises on invalid input.

  The runner reads the shared runtime keys (`:sources`, `:cache`,
  `:max_result_width`/`:max_result_height`/`:max_result_pixels`,
  `:max_body_bytes`, `:max_input_pixels`) straight from the validated
  config, so the returned keyword must carry them in the shapes
  `ImagePipe.Dialect.SharedConfig.validate_runtime!/1` produces — delegate
  the shared subset to it (as `ImagePipe.Dialect.Native` does) rather than
  hand-rolling those keys.
  """
  @callback validate_config!(config()) :: config()

  @doc """
  The `[:parse]` phase. Returns the parse result together with the span's
  stop metadata — metadata shape is dialect-owned for both outcomes.
  """
  @callback parse(Plug.Conn.t(), config()) ::
              {parse_result(), span_stop_metadata :: map()}

  @doc """
  Everything else decidable before any side effect: gates, source
  translation, negotiation (computed, carried as a deferred result), identity
  material, terminal selection.
  """
  @callback prepare(Plug.Conn.t(), request(), config()) ::
              {:ok, Resolved.t()} | {:error, term()}

  @doc "Shrink-on-load preflight for the sequential decode re-open."
  @callback decode_request(request(), SourceGeometry.t()) ::
              DecodePlanner.Request.t()

  @doc "The transform stage only; runs inside the runner's decode bracket."
  @callback execute(State.t(), SourceGeometry.t(), request(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  @doc "Renders any lifecycle error to the client; status vocabulary is dialect-owned."
  @callback render_error(Plug.Conn.t(), reason :: term(), config()) :: Plug.Conn.t()

  @doc """
  Optional: maps an error reason to the `[:request]` span's `:result` atom.
  Default: `ImagePipe.Telemetry.request_result/1`.
  """
  @callback classify_error(reason :: term()) :: atom()

  @optional_callbacks classify_error: 1

  @doc """
  Runs a dialect's own pipeline, converting its raises into `c:execute/4`'s
  tagged-tuple contract.

  A dialect calls this from inside its own `c:execute/4`; the runner rescues
  nothing on any dialect's behalf. The libvips pipeline is a concrete runtime
  boundary, so translating its exceptions is the dialect's job — but the
  `{:transform, _}` shape every dialect's error module pattern-matches is one
  contract, so it is produced in one place rather than copied per dialect.
  """
  @spec safe_transform((-> {:ok, State.t()} | {:error, term()})) ::
          {:ok, State.t()} | {:error, term()}
  def safe_transform(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end
end
