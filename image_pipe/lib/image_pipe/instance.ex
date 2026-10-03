defmodule ImagePipe.Instance do
  # Supervises one named configuration: the processes its caches need, then
  # the publisher that makes the configuration visible to mounts.
  @moduledoc false
  use Supervisor

  alias ImagePipe.Cache
  alias ImagePipe.Config
  alias ImagePipe.Instance.Publisher
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
            ]
          )

  @doc false
  def options_schema, do: @schema.schema

  # Validates and builds the configuration up front, so invalid options raise
  # in the caller, as `ImagePipe.Plug.init/1` does.
  def child_spec(options) do
    {instance, options} = Keyword.split(options, [:name, :urls, :config])

    case NimbleOptions.validate(instance, @schema) do
      {:ok, instance} ->
        name = Keyword.fetch!(instance, :name)
        config = %{base_config(instance[:config], options) | instance: name}

        urls =
          Map.new(instance[:urls], fn {url_name, url} ->
            {url_name, %{Config.override(config, url: url) | instance: name}}
          end)

        %{
          id: name,
          start: {__MODULE__, :start_link, [{name, config, urls}]},
          type: :supervisor
        }

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe instance: #{Exception.message(error)}"
    end
  end

  defp base_config(nil, options), do: Config.new!(options)
  defp base_config(config, options), do: Config.override(config, options)

  def start_link({name, _config, _urls} = instance),
    do: Supervisor.start_link(__MODULE__, instance, name: name)

  @impl true
  def init({name, config, urls}) do
    # The publisher starts last, so a published configuration always has its
    # cache processes. A cache restart leaves the publisher running.
    children = Cache.child_specs(config.options) ++ [{Publisher, {name, config, urls}}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate_urls(urls) do
    if Keyword.keyword?(urls) and Enum.all?(urls, &match?({_name, %URLConfig{}}, &1)),
      do: {:ok, urls},
      else: {:error, "expected a keyword list of ImagePipe.URL.config/1 values"}
  end
end
