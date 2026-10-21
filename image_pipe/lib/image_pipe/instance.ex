defmodule ImagePipe.Instance do
  # Supervises one named configuration: its processing pool, the processes its
  # caches need, the publisher that makes the configuration visible to mounts,
  # and the detector warmup.
  @moduledoc false
  use Supervisor

  require Logger

  alias ImagePipe.Cache
  alias ImagePipe.Config
  alias ImagePipe.Instance.Publisher
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector.Warmup

  @schema NimbleOptions.new!(
            name: [
              type: :atom,
              required: true,
              doc: """
              Name that `ImagePipe.Plug` mounts, `ImagePipe.run/4`, `ImagePipe.write/5`, \
              `ImagePipe.validate/2`, and `ImagePipe.url_config/1` use to find the instance. It \
              also names the instance's supervisor.
              """
            ],
            config: [
              type: {:struct, Config},
              type_doc: "`t:ImagePipe.Config.t/0`",
              doc:
                "A configuration from `ImagePipe.config/1` to start from. The other options override it."
            ],
            pool: [
              type: {:or, [{:in, [false]}, :keyword_list]},
              type_doc: "`t:keyword/0` or `false`",
              default: [],
              doc: """
              Options for the `ImagePipe.ProcessingPool` the instance starts, other \
              than `:name`, such as `[max_concurrency: 4, max_queue: 16]`. \
              `:max_concurrency` defaults to the VM's online schedulers. The pool \
              limits how many images the instance's mounts and `ImagePipe.run/4` \
              calls with its name process at once. With `false`, the instance starts \
              no pool and every request starts processing as it arrives. The \
              instance starts none either when its configuration names a pool in \
              `:processing_pool`. Options here then raise `ArgumentError`. The \
              instance's own pool is named after it, such as \
              `MyApp.Images.ProcessingPool`. See \
              [limiting concurrent processing](processing-controls.md).
              """
            ],
            detector_warmup: [
              type: {:or, [{:in, [:all, false]}, {:list, :string}]},
              type_doc: "`:all`, `false`, or a list of class names",
              default: :all,
              doc: """
              Which detector classes to load models for when the instance starts, using \
              `ImagePipe.Transform.Detector.Warmup`. `:all` loads every model, a list \
              such as `["face"]` loads only the models those classes need, and `false` \
              loads none. Nothing is loaded when the configuration's detector isn't \
              available. A class the detector doesn't support raises `ArgumentError`.
              """
            ]
          )

  @doc false
  def options_schema, do: @schema.schema

  # Validates and builds the configuration up front, so invalid options raise
  # in the caller, as `ImagePipe.Plug.init/1` does.
  def child_spec(options) do
    {instance, options} =
      Keyword.split(options, [:name, :config, :pool, :detector_warmup])

    case NimbleOptions.validate(instance, @schema) do
      {:ok, instance} ->
        name = Keyword.fetch!(instance, :name)

        {config, pool} =
          processing_pool!(base_config(instance[:config], options), name, instance[:pool])

        config = %{
          config
          | instance: name,
            options: Cache.put_source_records(config.options, name)
        }

        check_warmup_classes!(config, instance[:detector_warmup])

        %{
          id: name,
          start: {__MODULE__, :start_link, [{name, config, pool, instance[:detector_warmup]}]},
          type: :supervisor
        }

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe instance: #{Exception.message(error)}"
    end
  end

  defp base_config(nil, options), do: Config.new!(options)
  defp base_config(config, options), do: Config.override(config, options)

  # Unless the configuration names a pool, the instance starts its own, named
  # after it so that the published configuration survives a pool restart.
  defp processing_pool!(config, name, pool) do
    case {Keyword.get(config.options, :processing_pool), pool} do
      {nil, false} ->
        {config, nil}

      {nil, options} ->
        pool_name = Module.concat(name, ProcessingPool)
        {Config.override(config, processing_pool: pool_name), pool_options!(pool_name, options)}

      {_named, pool} when pool in [[], false] ->
        {config, nil}

      {_named, _options} ->
        raise ArgumentError,
              "invalid ImagePipe instance: pool: can't be combined with processing_pool, " <>
                "which names a pool started elsewhere"
    end
  end

  defp pool_options!(pool_name, options) do
    schema = Keyword.delete(ProcessingPool.options_schema(), :name)
    options = Keyword.merge([max_concurrency: System.schedulers_online()], options)

    case NimbleOptions.validate(options, schema) do
      {:ok, options} ->
        [name: pool_name] ++ options

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe instance: pool: #{Exception.message(error)}"
    end
  end

  def start_link({name, _config, _pool, _warmup} = instance),
    do: Supervisor.start_link(__MODULE__, instance, name: name)

  @impl true
  def init({name, config, pool, warmup}) do
    warn_unsigned(name, config.options)

    # The pool and the caches start before the publisher, so a published
    # configuration always has its processes. A restart of either leaves the
    # publisher running.
    children =
      pool_children(pool) ++
        Cache.child_specs(config.options) ++
        [{Publisher, {name, config}}] ++ warmup_children(config, warmup)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp warn_unsigned(name, options) do
    if Keyword.fetch!(options, :allow_unsigned) and Keyword.fetch!(options, :keys).values == [] do
      Logger.warning(
        "ImagePipe instance #{inspect(name)} serves unsigned URLs (allow_unsigned: true). " <>
          "Keep its mounts on a private network, and sign URLs (:keys) for public traffic."
      )
    end
  end

  defp pool_children(nil), do: []
  defp pool_children(options), do: [{ProcessingPool, options}]

  defp check_warmup_classes!(config, classes) when is_list(classes) do
    case Transform.resolve_detector(Keyword.fetch!(config.options, :detector)) do
      nil ->
        :ok

      module ->
        case classes -- module.supported_classes([]) do
          [] ->
            :ok

          unknown ->
            raise ArgumentError,
                  "invalid ImagePipe instance: detector_warmup: unknown classes " <>
                    inspect(Enum.sort(unknown))
        end
    end
  end

  defp check_warmup_classes!(_config, _classes), do: :ok

  defp warmup_children(_config, false), do: []

  defp warmup_children(config, classes) do
    detector = Keyword.fetch!(config.options, :detector)

    if Transform.detector_available?(detector, classes: classes),
      do: [{Warmup, detector: detector, classes: classes}],
      else: []
  end
end
