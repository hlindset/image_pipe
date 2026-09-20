defmodule ImagePipe.Source.Origin do
  @moduledoc """
  Origin cache evidence, kept separately from the source's byte identity.

  Validators are used only for upstream conditional requests. A weak origin
  ETag never becomes a strong representation ETag. Request header values and
  the effective resource URL are digested; raw credentials are not retained.
  """

  alias ImagePipe.MaterialDigest
  alias ImagePipe.Source.CacheState
  alias ImagePipe.Source.HTTPDate
  alias Plug.Conn.Utils

  @headers ~w(cache-control date age expires etag last-modified vary content-type content-length)
  @enforce_keys [
    :status,
    :headers,
    :requested_at,
    :received_at,
    :resource,
    :vary,
    :authenticated?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: integer(),
          headers: %{String.t() => [String.t()]},
          requested_at: integer(),
          received_at: integer(),
          resource: binary(),
          vary: %{String.t() => binary()},
          authenticated?: boolean()
        }

  @doc false
  def valid?(%__MODULE__{} = origin) do
    origin.status in 200..299 and is_integer(origin.requested_at) and
      is_integer(origin.received_at) and is_boolean(origin.authenticated?) and
      is_binary(origin.resource) and byte_size(origin.resource) == 32 and
      valid_headers?(origin.headers) and valid_vary?(origin.vary)
  end

  def valid?(_origin), do: false

  defp valid_headers?(headers) when is_map(headers) do
    Enum.all?(headers, fn {name, values} ->
      name in @headers and is_list(values) and Enum.all?(values, &is_binary/1)
    end)
  end

  defp valid_headers?(_headers), do: false

  defp valid_vary?(vary) when is_map(vary) do
    Enum.all?(vary, fn {name, digest} ->
      is_binary(name) and is_binary(digest) and byte_size(digest) == 32
    end)
  end

  defp valid_vary?(_vary), do: false

  @doc false
  def from_response(response, {requested_at, received_at}, previous_headers \\ %{}) do
    request = response.request
    headers = Map.take(response.headers, @headers)

    vary =
      headers
      |> Map.get("vary", Map.get(previous_headers, "vary", []))
      |> Enum.flat_map(&Utils.list/1)
      |> Enum.map(&String.downcase/1)

    %__MODULE__{
      status: response.status,
      headers: headers,
      requested_at: requested_at,
      received_at: received_at,
      resource: resource(request.url),
      vary: Map.new(vary, &{&1, MaterialDigest.of(Map.get(request.headers, &1, []))}),
      authenticated?: Map.has_key?(request.headers, "authorization")
    }
  end

  @doc "Evaluates current host policy against retained origin evidence."
  def cache_state(origin, policy, stable?) do
    state =
      CacheState.from_headers(
        origin.headers,
        policy,
        stable?,
        {origin.requested_at, origin.received_at},
        origin.authenticated?
      )

    %{state | storable?: state.storable? and origin.status == 200}
  end

  @doc "Returns origin validators, preferring ETag to Last-Modified."
  def validator_headers(%__MODULE__{headers: headers} = origin) do
    case Map.get(headers, "etag") do
      [etag] ->
        case Regex.match?(~r/\A(?:W\/)?"[\x21\x23-\x7E\x80-\xFF]*"\z/, etag) do
          true -> [{"if-none-match", etag}]
          false -> modified_validator(origin)
        end

      _missing ->
        modified_validator(origin)
    end
  end

  defp modified_validator(origin) do
    with [modified] <- Map.get(origin.headers, "last-modified", []),
         {:ok, _timestamp} <- HTTPDate.parse(modified, origin.received_at) do
      [{"if-modified-since", modified}]
    else
      _invalid -> []
    end
  end

  @doc false
  def conditional_headers(nil, _request), do: []

  def conditional_headers(%__MODULE__{} = previous, request) do
    case previous.resource == resource(request.url) and matches?(previous, request.headers) do
      true -> validator_headers(previous)
      false -> []
    end
  end

  @doc "Checks origin Vary against effective outbound request headers."
  def matches?(%__MODULE__{vary: vary}, request_headers) do
    not Map.has_key?(vary, "*") and
      Enum.all?(vary, fn {name, digest} ->
        MaterialDigest.of(Map.get(request_headers, name, [])) == digest
      end)
  end

  @doc false
  def refreshed(previous, response) do
    case compatible_validator?(previous.headers, response.headers) do
      true ->
        headers = previous.headers |> Map.drop(["age", "date"]) |> Map.merge(response.headers)
        {:ok, %{response | status: 200, headers: headers}}

      false ->
        {:error, {:source, :invalid_not_modified}}
    end
  end

  defp compatible_validator?(previous, %{"etag" => [current]}) do
    Regex.match?(~r/\A(?:W\/)?"[\x21\x23-\x7E\x80-\xFF]*"\z/, current) and
      case Map.get(previous, "etag") do
        [etag] -> String.trim_leading(etag, "W/") == String.trim_leading(current, "W/")
        _missing -> true
      end
  end

  defp compatible_validator?(_previous, %{"etag" => _ambiguous}), do: false
  defp compatible_validator?(_previous, _current), do: true

  defp resource(url), do: url |> to_string() |> MaterialDigest.of()
end
