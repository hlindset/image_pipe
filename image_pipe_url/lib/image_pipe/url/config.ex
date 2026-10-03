defmodule ImagePipe.URL.Config do
  @moduledoc """
  URL settings shared by a builder and the server that serves its URLs.

  Build one with `ImagePipe.URL.config/1`, which lists the options. On the
  serving side, pass the same value to `ImagePipe.config/1` as `:url`, so the
  server verifies signatures and decrypts sources with the same keys.
  Inspecting the struct hides its values.
  """

  alias ImagePipe.API.Presets
  alias ImagePipe.Security

  @enforce_keys [:options]
  @derive {Inspect, except: [:options]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{options: keyword()}

  @schema NimbleOptions.new!(
            base_url: [
              type: :string,
              default: "",
              doc: """
              Prefix for generated URLs: an HTTP(S) URL such as
              `"https://cdn.example.com/images"`, a root-relative path such as
              `"/images"`, or a relative path such as `"images"`. A trailing `/` is
              removed. Path segments use unescaped ASCII letters, digits, `-`, `.`,
              `_`, or `~`. A base URL with credentials, a query string, a fragment,
              an empty segment, or a `.` or `..` segment raises. With the default,
              URLs start with `/`, such as `/w=400/src/cat.jpg`.
              """
            ],
            mount_presets: [
              type: :keyword_list,
              doc: """
              The server's presets, so `ImagePipe.URL.validate/1` and
              `ImagePipe.URL.url/3` check plans as the server does. It never changes
              a generated URL, but a copy that differs from the server gives wrong
              validation results. In an app that serves its own URLs,
              `ImagePipe.url_config/1` returns the URL configuration with this
              filled in, and `ImagePipe.config/1` raises for a URL configuration
              that sets it.
              """,
              keys: [
                presets: [
                  type: :any,
                  default: %{},
                  type_doc: "`t:map/0`",
                  doc: """
                  The server's presets: preset names mapped to option fragments
                  such as `"w=400/h=300/fit=cover"`, or to `ImagePipe.URL` builders.
                  """
                ],
                request_defaults: [
                  type: :any,
                  type_doc: "`t:String.t/0` or `t:ImagePipe.URL.t/0`",
                  doc: "The server's request defaults, as a fragment or builder."
                ],
                preset_lookup: [
                  type: :boolean,
                  default: false,
                  doc: """
                  Set to `true` when the server has a preset lookup. A plan that
                  names a preset missing from `:presets` is then not checked at all,
                  because only the server can resolve the name.
                  """
                ]
              ]
            ]
          )

  @doc false
  # Every option `ImagePipe.URL.config/1` accepts, in documentation order.
  @spec schema() :: keyword()
  def schema do
    options = Security.options_schema() ++ @schema.schema
    order = [:base_url, :keys, :encrypt_source, :source_encryption_keys, :iv_mode, :mount_presets]
    Enum.map(order, &{&1, Keyword.fetch!(options, &1)})
  end

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) when is_list(options) do
    {security, remaining} = Security.extract!(options)

    case NimbleOptions.validate(remaining, @schema) do
      {:ok, validated} ->
        base_url = validated |> Keyword.fetch!(:base_url) |> base_url!()

        options = security ++ [base_url: base_url] ++ mount_presets!(validated[:mount_presets])
        %__MODULE__{options: options}

      {:error, %NimbleOptions.ValidationError{key: :base_url}} ->
        invalid_base!()

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe.URL configuration: #{Exception.message(error)}"
    end
  end

  # What the builder knows about the serving mount's presets, used only for
  # validation. `ImagePipe.config/1` injects its own with `put_mount_presets/2`.
  @type mount_presets :: %{presets: map(), request_defaults: map() | nil, lookup?: boolean()}

  @doc false
  @spec put_mount_presets(t(), mount_presets()) :: t()
  def put_mount_presets(%__MODULE__{options: options} = config, mount_presets),
    do: %{config | options: Keyword.put(options, :mount_presets, mount_presets)}

  defp mount_presets!(nil), do: []

  defp mount_presets!(options) do
    presets =
      Map.new(Keyword.fetch!(options, :presets), fn {name, value} -> {name, plan(value)} end)

    case Presets.compile(presets, plan(options[:request_defaults])) do
      {:ok, compiled} ->
        [mount_presets: Map.put(compiled, :lookup?, Keyword.fetch!(options, :preset_lookup))]

      {:error, message} ->
        raise ArgumentError, "invalid ImagePipe.URL configuration: mount_presets: #{message}"
    end
  end

  defp plan(value) when is_struct(value, ImagePipe.URL), do: {:plan, value.plan}
  defp plan(value), do: value

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
