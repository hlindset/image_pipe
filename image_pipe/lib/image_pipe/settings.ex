defmodule ImagePipe.Settings do
  @options [
    tmp_dir: [
      type: {:custom, __MODULE__, :directory, []},
      type_doc: "`t:Path.t/0`",
      doc: """
      The directory that holds the `image_pipe` directory, where originals
      are staged while they download and where the part of a response a slow
      client hasn't read yet is spooled. It must exist. Defaults to the
      system temporary directory (see `System.tmp_dir!/0`).
      """
    ],
    max_buffered_bytes: [
      type: :non_neg_integer,
      default: 256 * 1024 * 1024,
      doc: "Bytes held in memory for slow clients, across all responses."
    ],
    max_spooled_bytes: [
      type: :non_neg_integer,
      default: 2 * 1024 * 1024 * 1024,
      doc: """
      Bytes spooled to files in `tmp_dir` for slow clients, across all
      responses. `0` turns spooling off.
      """
    ]
  ]

  @moduledoc """
  Settings that apply to every ImagePipe configuration in the VM, read from
  the `:image_pipe` application environment when the application starts.

      # config/runtime.exs
      config :image_pipe,
        tmp_dir: "/var/lib/my_app/tmp",
        max_spooled_bytes: 512 * 1024 * 1024

  #{NimbleOptions.docs(@options)}

  Unknown keys raise, as do invalid values, and the application doesn't
  start. See [slow clients](deployment.md#slow-clients) for how the limits
  are used, and `ImagePipe.delivery_stats/0` for what they hold.
  """

  use Boundary, top_level?: true, deps: [ImagePipe.Delivery, ImagePipe.Execution]

  alias ImagePipe.Delivery.Budget
  alias ImagePipe.Execution.Staging

  @schema NimbleOptions.new!(@options)

  @doc false
  def options_schema, do: @schema.schema

  @doc false
  # Validates the settings and applies them. The application calls it at
  # start with its environment.
  @spec apply!(keyword()) :: :ok
  def apply!(settings) do
    case NimbleOptions.validate(settings, @schema) do
      {:ok, settings} ->
        Staging.init(Keyword.get(settings, :tmp_dir))

        Budget.init(
          memory: Keyword.fetch!(settings, :max_buffered_bytes),
          spool: Keyword.fetch!(settings, :max_spooled_bytes)
        )

      {:error, error} ->
        raise ArgumentError, "invalid :image_pipe settings: #{Exception.message(error)}"
    end
  end

  @doc false
  def directory(path) when is_binary(path) do
    if File.dir?(path), do: {:ok, path}, else: {:error, "#{inspect(path)} is not a directory"}
  end

  def directory(other), do: {:error, "expected a string, got: #{inspect(other)}"}
end
