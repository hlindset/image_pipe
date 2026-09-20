defmodule ImagePipe.Source.CacheState do
  @moduledoc """
  Source-derived storage permission and absolute freshness deadlines.

  Both caches retain this state with their entries. Reading an entry or
  generating a new output never changes its deadlines. Only a successful
  source response or revalidation produces new state.

  Header input uses Req's normalized lowercase names and lists of values.
  Times are Unix seconds. Age includes apparent origin age and request delay
  (RFC 9111 section 4.2.3). No heuristic freshness is assumed.
  """

  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.HTTPDate
  alias Plug.Conn.Utils

  @enforce_keys [:storable?, :fresh_until, :stale_until]
  defstruct @enforce_keys

  @type deadline :: integer() | :infinity | nil
  @type t :: %__MODULE__{
          storable?: boolean(),
          fresh_until: deadline(),
          stale_until: deadline()
        }

  @spec from_headers(map(), CachePolicy.t(), boolean(), {integer(), integer()}, boolean()) :: t()
  def from_headers(headers, policy, stable?, {requested_at, received_at}, authenticated? \\ false) do
    directives = directives(Map.get(headers, "cache-control", []))
    age = age(headers, requested_at, received_at)
    lifetime = lifetime(headers, directives, policy, received_at)

    {fresh_until, stale_until} =
      deadlines(stable?, age, received_at, lifetime, stale_window(directives, policy))

    %__MODULE__{
      storable?:
        storable?(headers, directives, Keyword.get(policy, :storage, :origin), authenticated?),
      fresh_until: fresh_until,
      stale_until: stale_until
    }
  end

  @spec status(t(), integer()) :: :not_storable | :fresh | :stale | :requires_validation
  def status(%__MODULE__{storable?: false}, _now), do: :not_storable
  def status(%__MODULE__{fresh_until: :infinity}, _now), do: :fresh
  def status(%__MODULE__{fresh_until: nil}, _now), do: :requires_validation
  def status(%__MODULE__{fresh_until: deadline}, now) when now < deadline, do: :fresh
  def status(%__MODULE__{stale_until: deadline}, now) when now < deadline, do: :stale
  def status(%__MODULE__{}, _now), do: :requires_validation

  defp deadlines(true, _age, _received_at, _lifetime, _stale_window),
    do: {:infinity, :infinity}

  defp deadlines(false, :invalid, _received_at, _lifetime, _stale_window), do: {nil, nil}

  defp deadlines(false, age, received_at, lifetime, stale_window) do
    fresh_until = received_at - age + lifetime
    {fresh_until, fresh_until + stale_window}
  end

  defp storable?(headers, directives, storage, authenticated?) do
    vary = headers |> Map.get("vary", []) |> Enum.flat_map(&Utils.list/1)

    "*" not in vary and storage_allowed?(storage, directives) and
      authorized_storage?(storage, directives, authenticated?)
  end

  defp authorized_storage?(:allow, _directives, _authenticated?), do: true
  defp authorized_storage?(_storage, _directives, false), do: true

  defp authorized_storage?(_storage, directives, true) do
    directives["public"] == [nil] or directives["must-revalidate"] == [nil] or
      seconds(Map.get(directives, "s-maxage", []), :invalid) != :invalid
  end

  defp storage_allowed?(:deny, _directives), do: false
  defp storage_allowed?(:allow, _directives), do: true

  defp storage_allowed?(:origin, directives),
    do: not Enum.any?(["no-store", "private"], &Map.has_key?(directives, &1))

  defp lifetime(headers, directives, policy, received_at) do
    origin = origin_lifetime(headers, directives, received_at)

    case {Keyword.get(policy, :freshness, :origin), origin} do
      {{:force, seconds}, _origin} -> seconds
      {{:fallback, seconds}, nil} -> seconds
      {_policy, nil} -> 0
      {_policy, seconds} -> seconds
    end
  end

  defp origin_lifetime(headers, directives, received_at) do
    cond do
      Map.has_key?(directives, "no-cache") -> 0
      Map.has_key?(directives, "s-maxage") -> seconds(directives["s-maxage"], 0)
      Map.has_key?(directives, "max-age") -> seconds(directives["max-age"], 0)
      Map.has_key?(headers, "expires") -> expires_lifetime(headers, received_at)
      true -> nil
    end
  end

  defp expires_lifetime(headers, received_at) do
    case {date(headers, "expires", received_at), date(headers, "date", received_at)} do
      {expires, origin_date} when is_integer(expires) and origin_date != :invalid ->
        max(0, expires - (origin_date || received_at))

      _invalid ->
        0
    end
  end

  defp stale_window(directives, policy) do
    case Keyword.get(policy, :stale_while_revalidate, :origin) do
      {:force, seconds} -> seconds
      :disabled -> 0
      :origin -> origin_stale_window(directives)
    end
  end

  defp origin_stale_window(directives) do
    prohibited? =
      Enum.any?(
        ["no-cache", "must-revalidate", "proxy-revalidate", "s-maxage"],
        &Map.has_key?(directives, &1)
      )

    case prohibited? do
      true -> 0
      false -> seconds(Map.get(directives, "stale-while-revalidate", []), 0)
    end
  end

  defp age(headers, requested_at, received_at) do
    origin_date = date(headers, "date", received_at)
    age_value = seconds(Map.get(headers, "age", ["0"]), :invalid)

    case {origin_date, age_value} do
      {:invalid, _age} ->
        :invalid

      {_date, :invalid} ->
        :invalid

      {date, age} ->
        apparent_age = max(0, received_at - (date || received_at))
        max(apparent_age, age + max(0, received_at - requested_at))
    end
  end

  defp date(headers, name, now) do
    case Map.get(headers, name, []) do
      [] ->
        nil

      [value] ->
        case HTTPDate.parse(value, now) do
          {:ok, timestamp} -> timestamp
          :error -> :invalid
        end

      _multiple ->
        :invalid
    end
  end

  defp seconds([value], fallback) when is_binary(value) do
    case Regex.match?(~r/\A[0-9]+\z/, value) do
      true -> min(String.to_integer(value), 2_147_483_648)
      false -> fallback
    end
  end

  defp seconds(_values, fallback), do: fallback

  # Split only outside quoted strings; extensions may contain commas.
  defp directives(values) do
    values
    |> Enum.flat_map(&split_directives(&1, false, [], []))
    |> Enum.map(fn directive ->
      case String.split(directive, "=", parts: 2) do
        [name, value] ->
          {String.downcase(String.trim(name)), String.trim(value) |> unquote_value()}

        [name] ->
          {String.downcase(String.trim(name)), nil}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp split_directives(<<>>, false, part, parts),
    do: Enum.reverse([part |> Enum.reverse() |> IO.iodata_to_binary() | parts])

  defp split_directives(<<>>, true, _part, _parts), do: ["no-cache", "no-store"]

  defp split_directives(<<?\\, char, rest::binary>>, true, part, parts),
    do: split_directives(rest, true, [char, ?\\ | part], parts)

  defp split_directives(<<?", rest::binary>>, quoted?, part, parts),
    do: split_directives(rest, not quoted?, [?" | part], parts)

  defp split_directives(<<?,, rest::binary>>, false, part, parts),
    do:
      split_directives(rest, false, [], [part |> Enum.reverse() |> IO.iodata_to_binary() | parts])

  defp split_directives(<<char, rest::binary>>, quoted?, part, parts),
    do: split_directives(rest, quoted?, [char | part], parts)

  defp unquote_value(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_value(value), do: value
end
