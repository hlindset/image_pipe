defmodule ImagePipe.Telemetry.Catalog do
  @moduledoc false
  # Every telemetry event ImagePipe emits, by stage (the event name after the
  # prefix). The default Logger and the span tracer both subscribe from here,
  # so an event added here reaches both, and `docs/telemetry-events.md`
  # documents each one.
  #
  # Each entry is `{stage, kind, group}` or `{stage, kind, group, :trace_only}`:
  #
  #   * kind: `:span` (emitted as `:start`, `:stop`, and `:exception`) or
  #     `:oneshot` (one event, its full name is the stage).
  #   * group: the Logger event group that selects it (`attach_default_logger/1`'s
  #     `:events` option).
  #   * `:trace_only`: traced, but not logged.

  @groups [:request, :parse, :source, :transform, :cache, :output, :http_cache, :debug]

  @entries [
    {[:request], :span, :request},
    {[:request, :ignored_options], :oneshot, :request},
    {[:processing, :admission], :span, :request},
    {[:processing, :execute], :span, :request},
    {[:send], :span, :request},
    {[:deliver], :span, :request},
    {[:encode], :span, :request},
    {[:encode, :search], :span, :request},
    {[:encode, :search, :probe], :span, :request},
    # Probe cost spans time eager work: the encode, then the decode and score.
    # They fire for every probe, so they're traced but not logged.
    {[:encode, :search, :probe, :encode], :span, :request, :trace_only},
    {[:encode, :search, :probe, :ssimulacra2, :decode], :span, :request, :trace_only},
    {[:encode, :search, :probe, :ssimulacra2, :metric], :span, :request, :trace_only},
    {[:encode, :search, :probe, :chosen], :oneshot, :request},
    {[:parse], :span, :parse},
    {[:preset, :lookup], :span, :parse},
    {[:source, :resolve], :span, :source},
    {[:source, :fetch], :span, :source},
    {[:source, :fetch_decode], :span, :source},
    {[:source, :stage], :span, :source},
    {[:source, :watermark], :span, :source},
    {[:transform, :execute], :span, :transform},
    {[:transform, :input_color_management], :span, :transform},
    {[:transform, :operation], :span, :transform},
    {[:transform, :materialize], :span, :transform},
    {[:transform, :detect], :span, :transform},
    {[:transform, :detect, :model], :span, :transform},
    {[:transform, :detect, :skipped], :oneshot, :transform},
    {[:transform, :detect, :blend], :oneshot, :transform},
    {[:cache, :lookup], :span, :cache},
    {[:cache, :input], :span, :cache},
    {[:cache, :refresh], :span, :cache},
    {[:cache, :write], :span, :cache},
    {[:cache, :admission], :span, :cache},
    {[:cache, :sweep], :span, :cache},
    {[:cache, :rescan], :span, :cache},
    {[:cache, :coordination], :oneshot, :cache},
    {[:cache, :stage], :oneshot, :cache},
    {[:cache, :eviction, :stop], :oneshot, :cache},
    {[:output, :negotiate], :span, :output},
    {[:output, :terminal], :span, :output},
    {[:output, :clamp], :oneshot, :output},
    {[:http_cache, :prepare], :oneshot, :http_cache},
    {[:http_cache, :conditional, :match], :oneshot, :http_cache},
    {[:http_cache, :fallback, :no_store], :oneshot, :http_cache},
    {[:http_cache, :cache_hit, :headers], :oneshot, :http_cache},
    {[:debug, :collect, :error], :oneshot, :debug}
  ]

  @doc "The Logger's event groups."
  @spec groups() :: [atom()]
  def groups, do: @groups

  @doc "Every entry as `{stage, kind, group, logged?}`."
  @spec entries() :: [{[atom()], :span | :oneshot, atom(), boolean()}]
  def entries do
    for entry <- @entries do
      case entry do
        {stage, kind, group} -> {stage, kind, group, true}
        {stage, kind, group, :trace_only} -> {stage, kind, group, false}
      end
    end
  end

  @doc "The stages emitted as spans."
  @spec span_stages() :: [[atom()]]
  def span_stages, do: for({stage, :span, _group, _logged?} <- entries(), do: stage)

  @doc "The stages emitted as one-shot events."
  @spec oneshot_stages() :: [[atom()]]
  def oneshot_stages, do: for({stage, :oneshot, _group, _logged?} <- entries(), do: stage)

  @doc """
  The full names of the events the Logger subscribes to for `groups`, under
  `prefix`: each logged span's `:stop` and `:exception`, and each logged
  one-shot.
  """
  @spec logged_events([atom()], [atom()]) :: [[atom()]]
  def logged_events(groups, prefix) do
    for {stage, kind, group, true} <- entries(),
        group in groups,
        suffix <- suffixes(kind),
        do: prefix ++ stage ++ suffix
  end

  @doc """
  The full names of the events the tracer subscribes to under `prefix`:
  each span's `:start`, `:stop`, and `:exception`, and each one-shot.
  """
  @spec traced_events([atom()]) :: [[atom()]]
  def traced_events(prefix) do
    for {stage, kind, _group, _logged?} <- entries(),
        suffix <- if(kind == :span, do: [[:start], [:stop], [:exception]], else: [[]]),
        do: prefix ++ stage ++ suffix
  end

  defp suffixes(:span), do: [[:stop], [:exception]]
  defp suffixes(:oneshot), do: [[]]
end
