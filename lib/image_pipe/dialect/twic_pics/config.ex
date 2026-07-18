defmodule ImagePipe.Dialect.TwicPics.Config do
  @moduledoc false

  alias ImagePipe.Config, as: NeutralConfig
  alias ImagePipe.Dialect.SharedConfig

  @dialect_keys [
    :storage_inputs,
    :detector,
    :detector_required,
    :allow_debug_headers
  ]

  @dialect_schema NimbleOptions.new!(
                    storage_inputs: [
                      type: {:list, {:custom, SharedConfig, :validate_storage_input, []}},
                      default: []
                    ],
                    detector: [
                      type: {:or, [{:in, [:default, nil]}, :atom]},
                      default: :default
                    ],
                    detector_required: [
                      type: :boolean,
                      default: false
                    ],
                    allow_debug_headers: [
                      type: :boolean,
                      default: false
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {neutral, rest} = Keyword.split(rest, NeutralConfig.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    reject_unknown!(unknown)

    SharedConfig.validate_runtime!(shared)
    |> Keyword.merge(NeutralConfig.resolve!(neutral, []))
    |> Keyword.merge(validate_dialect!(dialect))
  end

  defp reject_unknown!([]), do: :ok

  defp reject_unknown!(unknown) do
    raise ArgumentError,
          "unknown ImagePipe.Dialect.TwicPics option(s): #{inspect(Keyword.keys(unknown))}"
  end

  defp validate_dialect!(dialect) do
    case NimbleOptions.validate(dialect, @dialect_schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.TwicPics options: #{Exception.message(error)}"
    end
  end
end
