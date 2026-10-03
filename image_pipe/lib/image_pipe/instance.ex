defmodule ImagePipe.Instance do
  # Supervises one named configuration: the processes its caches need, the
  # publisher that makes the configuration visible to mounts, and the detector
  # warmup.
  @moduledoc false
  use Supervisor

  alias ImagePipe.Cache
  alias ImagePipe.Config
  alias ImagePipe.Instance.Publisher
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector.Warmup
  alias ImagePipe.URL.Config, as: URLConfig

  @schema NimbleOptions.new!(
            name: [
              type: :atom,
              required: true,
              doc: """
              Name that mounts and `ImagePipe.config!/1` use to find the instance. It \
              also names the instance's supervisor.
              """
            ],
            urls: [
              type: {:custom, __MODULE__, :validate_urls, []},
              type_doc: "`t:keyword/0`",
              default: [],
              doc: """
              Named URL configurations from `ImagePipe.URL.config/1`, such as \
              `[signed: ImagePipe.URL.config(keys: [key])]`. A mount picks one with its \
              `:url` option, so mounts with different signing keys share one instance \
              and its caches.
              """
            ],
            config: [
              type: {:struct, Config},
              type_doc: "`t:ImagePipe.Config.t/0`",
              doc:
                "A configuration from `ImagePipe.config/1` to start from. The other options override it."
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
    {instance, options} = Keyword.split(options, [:name, :urls, :config, :detector_warmup])

    case NimbleOptions.validate(instance, @schema) do
      {:ok, instance} ->
        name = Keyword.fetch!(instance, :name)
        config = %{base_config(instance[:config], options) | instance: name}
        check_warmup_classes!(config, instance[:detector_warmup])

        urls =
          Map.new(instance[:urls], fn {url_name, url} ->
            {url_name, %{Config.override(config, url: url) | instance: name}}
          end)

        %{
          id: name,
          start: {__MODULE__, :start_link, [{name, config, urls, instance[:detector_warmup]}]},
          type: :supervisor
        }

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe instance: #{Exception.message(error)}"
    end
  end

  defp base_config(nil, options), do: Config.new!(options)
  defp base_config(config, options), do: Config.override(config, options)

  def start_link({name, _config, _urls, _warmup} = instance),
    do: Supervisor.start_link(__MODULE__, instance, name: name)

  @impl true
  def init({name, config, urls, warmup}) do
    # The publisher starts after the caches, so a published configuration
    # always has its cache processes. A cache restart leaves the publisher
    # running.
    children =
      Cache.child_specs(config.options) ++
        [{Publisher, {name, config, urls}}] ++ warmup_children(config, warmup)

    Supervisor.init(children, strategy: :one_for_one)
  end

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

  @doc false
  def validate_urls(urls) do
    if Keyword.keyword?(urls) and Enum.all?(urls, &match?({_name, %URLConfig{}}, &1)),
      do: {:ok, urls},
      else: {:error, "expected a keyword list of ImagePipe.URL.config/1 values"}
  end
end
