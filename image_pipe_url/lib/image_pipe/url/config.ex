defmodule ImagePipe.URL.Config do
  @moduledoc """
  URL generation and verification settings shared by a builder and its serving mount.

  Construct with `ImagePipe.URL.config/1`, and pass the same value to
  `ImagePipe.config/1` as `:url` on the serving side. Inspection excludes its values.
  """

  alias ImagePipe.API.Presets
  alias ImagePipe.Security

  @enforce_keys [:options]
  @derive {Inspect, except: [:options]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{options: keyword()}

  @schema NimbleOptions.new!(
            base_url: [type: :string, default: ""],
            presets: [type: {:custom, Presets, :validate_config, []}, default: %{}],
            preset_lookup: [type: {:custom, Presets, :validate_lookup, []}],
            max_preset_lookups: [type: :pos_integer]
          )

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) when is_list(options) do
    {security, remaining} = Security.extract!(options)

    case NimbleOptions.validate(remaining, @schema) do
      {:ok, validated} ->
        base_url = validated |> Keyword.fetch!(:base_url) |> base_url!()

        options =
          security ++
            [base_url: base_url, presets: Keyword.fetch!(validated, :presets)] ++
            lookup_options!(validated)

        %__MODULE__{options: options}

      {:error, %NimbleOptions.ValidationError{key: :base_url}} ->
        invalid_base!()

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe.URL configuration: #{Exception.message(error)}"
    end
  end

  defp lookup_options!(validated) do
    case {validated[:preset_lookup], validated[:max_preset_lookups]} do
      {nil, nil} ->
        []

      {nil, _max} ->
        raise ArgumentError,
              "invalid ImagePipe.URL configuration: max_preset_lookups requires preset_lookup"

      {lookup, max} ->
        [preset_lookup: lookup, max_preset_lookups: max || 32]
    end
  end

  defp base_url!(value) do
    with {:ok, uri} <- URI.new(value),
         true <- valid_authority?(uri),
         true <- is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo),
         false <- String.contains?(uri.path || "", "//"),
         true <- valid_path?(uri.path || "") do
      String.trim_trailing(value, "/")
    else
      _invalid -> invalid_base!()
    end
  end

  defp valid_authority?(%URI{scheme: nil, host: nil, port: nil}), do: true

  defp valid_authority?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp valid_authority?(_uri), do: false

  defp valid_path?(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.split("/")
    |> valid_segments?()
  end

  defp valid_segments?([""]), do: true

  defp valid_segments?(segments),
    do:
      Enum.all?(segments, &(&1 not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, &1)))

  defp invalid_base!,
    do:
      raise(
        ArgumentError,
        "base_url must be an HTTP(S) URL or canonical unescaped path prefix without credentials, query, or fragment"
      )
end
