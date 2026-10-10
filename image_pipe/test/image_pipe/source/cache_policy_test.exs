defmodule ImagePipe.Source.CachePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.CacheState

  defp state(headers, overrides \\ [], stable? \\ false) do
    {:ok, policy} = CachePolicy.validate(overrides)
    CacheState.from_headers(headers, policy, stable?, {990, 1_000})
  end

  test "storage permission is independent of forced freshness and immutability" do
    for directive <- ["no-store", "private", ~s(private="ETag")],
        stable? <- [true, false] do
      headers = %{"cache-control" => [directive], "etag" => [~s("v1")]}
      denied = state(headers, [freshness: {:force, 60}], stable?)
      assert CacheState.status(denied, 1_000) == :not_storable

      allowed = state(headers, [storage: :allow, freshness: {:force, 60}], stable?)

      assert CacheState.status(allowed, 1_000) == :fresh
    end
  end

  test "immutable sources have no deadlines but remain subject to storage permission" do
    immutable = state(%{"cache-control" => ["no-cache, max-age=0"]}, [], true)
    assert immutable.fresh_until == :infinity
    assert CacheState.status(immutable, 9_999_999) == :fresh
    assert CacheState.status(state(%{}, [storage: :deny], true), 1_000) == :not_storable
  end

  test "fallback only applies when origin freshness is absent" do
    assert state(%{}, freshness: {:fallback, 60}).fresh_until == 1_050

    assert state(%{"cache-control" => ["max-age=20"]}, freshness: {:fallback, 60}).fresh_until ==
             1_010

    assert state(%{"cache-control" => ["no-cache"]}, freshness: {:fallback, 60}).fresh_until ==
             990

    assert state(%{"cache-control" => ["max-age=broken"]}, freshness: {:fallback, 60}).fresh_until ==
             990
  end

  test "origin age and response delay consume the shared freshness deadline" do
    cached = state(%{"cache-control" => ["max-age=100"], "age" => ["40"]})
    assert cached.fresh_until == 1_050
    assert CacheState.status(cached, 1_049) == :fresh
    assert CacheState.status(cached, 1_050) == :requires_validation
  end

  test "shared max-age takes precedence and requires validation after expiry" do
    cached = state(%{"cache-control" => ["max-age=100, s-maxage=30, stale-while-revalidate=50"]})
    assert cached.fresh_until == 1_020
    assert CacheState.status(cached, 1_020) == :requires_validation
  end

  test "SWR has an absolute deadline and never extends on a hit" do
    cached = state(%{"cache-control" => ["max-age=30, stale-while-revalidate=20"]})
    assert CacheState.status(cached, 1_019) == :fresh
    assert CacheState.status(cached, 1_020) == :stale
    assert CacheState.status(cached, 1_039) == :stale
    assert CacheState.status(cached, 1_040) == :requires_validation
    assert cached.stale_until == 1_040
  end

  test "origin revalidation prohibitions require an explicit SWR override" do
    for directive <- ["no-cache", "must-revalidate", "proxy-revalidate"] do
      headers = %{"cache-control" => ["max-age=0, stale-while-revalidate=60, " <> directive]}
      assert CacheState.status(state(headers), 1_000) == :requires_validation

      assert CacheState.status(state(headers, stale_while_revalidate: {:force, 60}), 1_000) ==
               :stale
    end
  end

  test "qualified private and no-cache restrict only the stored fields they name" do
    etag = %{"etag" => [~s("v1")]}

    for {directive, extra, status} <- [
          {~s(private="Set-Cookie"), %{}, :fresh},
          {~s(private="set-cookie, X-Token"), etag, :fresh},
          {~s(private="etag"), %{}, :fresh},
          {~s(private="set-cookie, ETag"), etag, :not_storable},
          {~s(private="set-cookie", private), %{}, :not_storable},
          {~s(no-cache="Set-Cookie"), etag, :fresh},
          {~s(no-cache="etag"), etag, :requires_validation},
          {~s(no-cache="set-cookie", no-cache), %{}, :requires_validation}
        ] do
      headers = Map.put(extra, "cache-control", ["max-age=60, " <> directive])
      assert CacheState.status(state(headers), 1_000) == status, directive
    end

    headers = %{
      "cache-control" => [~s(max-age=0, stale-while-revalidate=60, no-cache="set-cookie")]
    }

    cached = state(headers)
    assert CacheState.status(cached, 1_000) == :stale
    assert cached.revalidation == :none
  end

  test "Vary star is unmatchable even with an explicit storage override" do
    cached = state(%{"vary" => ["*"]}, [storage: :allow], true)
    assert CacheState.status(cached, 1_000) == :not_storable
  end

  test "Date and Expires determine freshness without resetting origin age" do
    cached =
      state(%{
        "date" => [Req.Utils.format_http_date(DateTime.from_unix!(950))],
        "expires" => [Req.Utils.format_http_date(DateTime.from_unix!(1_020))]
      })

    assert cached.fresh_until == 1_020
  end

  test "all HTTP date forms preserve origin age, including case-insensitive dates" do
    {:ok, policy} = CachePolicy.validate([])

    for date <- [
          "Sun, 06 Nov 1994 08:49:37 GMT",
          "Sunday, 06-Nov-94 08:49:37 GMT",
          "Sun Nov  6 08:49:37 1994",
          "sun, 06 nov 1994 08:49:37 gmt"
        ] do
      cached =
        CacheState.from_headers(
          %{"date" => [date], "cache-control" => ["max-age=60"]},
          policy,
          false,
          {1_000_000_000, 1_000_000_001}
        )

      assert CacheState.status(cached, 1_000_000_001) == :requires_validation
      assert cached.fresh_until == 784_111_837
    end
  end

  test "an invalid or ambiguous Date cannot reset source age" do
    for dates <- [["invalid"], ["Thu, 01 Jan 1970 00:00:00 GMT", "Thu, 01 Jan 1970 00:01:00 GMT"]] do
      assert CacheState.status(
               state(%{"date" => dates, "cache-control" => ["max-age=60"]}),
               1_000
             ) == :requires_validation
    end
  end

  test "large freshness and SWR windows cannot make invalid age metadata reusable" do
    for header <- ["age", "date"] do
      cached =
        state(%{
          header => ["invalid"],
          "cache-control" => ["max-age=2147483648, stale-while-revalidate=60"]
        })

      assert CacheState.status(cached, 1_000) == :requires_validation
    end
  end

  test "duplicate and malformed lifetimes require validation" do
    for value <- ["max-age=10, max-age=60", "max-age=-1", "max-age=+60", "max-age=1.5"] do
      assert CacheState.status(state(%{"cache-control" => [value]}), 1_000) ==
               :requires_validation
    end
  end

  test "quoted extension values cannot inject cache directives" do
    cached = state(%{"cache-control" => [~s(extension="a,no-store,b", MAX-AGE="60")]})
    assert CacheState.status(cached, 1_000) == :fresh
  end

  test "policy validates host configuration and merges fields independently" do
    assert {:ok, defaults} = CachePolicy.validate(storage: :deny, freshness: {:fallback, 30})
    assert {:ok, override} = CachePolicy.validate(storage: :allow)

    assert Map.new(CachePolicy.merge(defaults, override)) == %{
             storage: :allow,
             freshness: {:fallback, 30}
           }

    for opts <- [[unknown: true], [freshness: 10], [freshness: {:force, -1}], [storage: true]] do
      assert {:error, _} = CachePolicy.validate(opts)
    end
  end

  property "elapsed time cannot make an expired source fresh again" do
    check all ttl <- integer(0..10_000), swr <- integer(0..1_000), later <- integer(0..10_000) do
      cached = state(%{"cache-control" => ["max-age=#{ttl}, stale-while-revalidate=#{swr}"]})
      assert CacheState.status(cached, 990 + ttl + swr + later) == :requires_validation
    end
  end
end
