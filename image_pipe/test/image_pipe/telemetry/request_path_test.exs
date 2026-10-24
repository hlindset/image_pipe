defmodule ImagePipe.Telemetry.RequestPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Telemetry

  @credentials ~w(X-Amz-Signature x-goog-credential sig AWSAccessKeyId X-Amz-Security-Token)

  describe "request_path/2" do
    test "ends the path at the source marker" do
      for marker <- ~w(src src64 enc) do
        assert Telemetry.request_path("/w=40/#{marker}/a/b.jpg", "") ==
                 "/w=40/#{marker}/REDACTED"
      end

      assert Telemetry.request_path("/src/https%3A%2F%2Fo.test%2Fa.jpg", "") == "/src/REDACTED"
    end

    test "keeps a marker with nothing after it" do
      assert Telemetry.request_path("/w=40/src", "") == "/w=40/src"
      assert Telemetry.request_path("/w=40/src/", "") == "/w=40/src/"
    end

    test "cuts at the first marker, wherever the path came from" do
      # A request sent under the wrong prefix, outside the mount.
      path = "/enc/w=2/src/https%3A%2F%2Fo.test%2Fa.jpg%3FX-Amz-Signature%3Dsecret"

      assert Telemetry.request_path(path, "") == "/enc/REDACTED"
      assert Telemetry.request_path("/src64/x/w=2/src/a.jpg", "") == "/src64/REDACTED"
    end

    test "replaces every wm-src64 token" do
      token = Base.url_encode64("https://o.test/mark.png", padding: false)

      assert Telemetry.request_path("/wm-src64=#{token}/w=40/src/a.jpg", "") ==
               "/wm-src64=REDACTED/w=40/src/REDACTED"

      assert Telemetry.request_path("/wm-src64=a/-/wm-src64=b", "") ==
               "/wm-src64=REDACTED/-/wm-src64=REDACTED"
    end

    test "folds a standard base64 token's tail into the redacted wm-src64 token" do
      assert Telemetry.request_path("/wm-src64=aHR0/cHM6+Ly9v/LnRl==/w=40/src/a.jpg", "") ==
               "/wm-src64=REDACTED/w=40/src/REDACTED"

      for next <- ["-", "wm-tile", "w=40", "rs=fill:10:10", "a.jpg"] do
        assert Telemetry.request_path("/wm-src64=a/b/#{next}", "") ==
                 "/wm-src64=REDACTED/#{next}"
      end

      assert Telemetry.request_path("/wm-src64=a/b/src/c", "") ==
               "/wm-src64=REDACTED/src/REDACTED"
    end

    test "replaces bytes that aren't valid UTF-8" do
      assert Telemetry.request_path(<<"/w=40/", 0xFF, ".jpg">>, "") == "/w=40/\uFFFD.jpg"

      assert Telemetry.request_path("/w=40", <<"v=1&", 0xFF, "=2">>) ==
               "/w=40?v=REDACTED&\uFFFD=REDACTED"
    end

    test "keeps the URL signature, wm-enc tokens, and other options" do
      path = "/sig=abc/wm-enc=AQRTMotB/w=40/rs=fill:10:10/src/a.jpg"

      assert Telemetry.request_path(path, "") ==
               "/sig=abc/wm-enc=AQRTMotB/w=40/rs=fill:10:10/src/REDACTED"
    end

    test "drops the query string after a marker" do
      assert Telemetry.request_path("/w=40/src/https://o.test/a.jpg", "X-Amz-Signature=s&a=1") ==
               "/w=40/src/REDACTED"
    end

    test "redacts every value in the query string of a path without a marker" do
      assert Telemetry.request_path("/w=40", "X-Amz-Signature=abc&token=key;keep=1&flag") ==
               "/w=40?X-Amz-Signature=REDACTED&token=REDACTED;keep=REDACTED&REDACTED"

      assert Telemetry.request_path("/favicon.ico", "v=2") == "/favicon.ico?v=REDACTED"
      assert Telemetry.request_path("/w=40", "") == "/w=40"
    end
  end

  describe "no credential survives" do
    property "in a path with a source, wherever the client put it" do
      check all(
              secret <- secret(),
              before <- list_of(option_segment(secret), max_length: 6),
              marker <- member_of(~w(src src64 enc)),
              tail <- list_of(tail_segment(secret), min_length: 1, max_length: 6),
              query <- query(secret)
            ) do
        path = "/" <> Enum.join(before ++ [marker | tail], "/")

        refute_secret(Telemetry.request_path(path, query), secret)
      end
    end

    property "in the query string of a path without a source" do
      check all(
              secret <- secret(),
              before <- list_of(option_segment(secret), max_length: 6),
              query <- query(secret)
            ) do
        path = "/" <> Enum.join(before, "/")

        refute_secret(Telemetry.request_path(path, query), secret)
      end
    end
  end

  describe "work per byte" do
    test "stays within a small constant" do
      paths = [
        String.duplicate("/a", 5_000),
        String.duplicate("/wm-src64=A", 900) <> "/src/x.jpg",
        "/w=40/src64/" <> String.duplicate("A", 9_900),
        "/w=40/src/" <> String.duplicate("a/", 4_900),
        "/enc" <> String.duplicate("/src/a%3Fb", 900)
      ]

      for path <- paths do
        assert reductions(fn -> Telemetry.request_path(path, "") end) < 100 * byte_size(path),
               binary_part(path, 0, 60)
      end

      query = String.duplicate("sig=a&", 1_600)

      assert reductions(fn -> Telemetry.request_path("/w=40", query) end) <
               100 * byte_size(query)
    end
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end

  # A credential value no other generator produces: lowercase letters never
  # appear in the other segments' alphabets.
  defp secret, do: map(string(?j..?q, min_length: 8, max_length: 16), &("zz" <> &1))

  defp presigned_url(secret) do
    gen all(
          name <- member_of(@credentials),
          spelling <- member_of([:as_is, :downcased, :escaped_name])
        ) do
      name =
        case spelling do
          :as_is -> name
          :downcased -> String.downcase(name)
          :escaped_name -> "%" <> Base.encode16(binary_part(name, 0, 1)) <> tail_of(name)
        end

      "https://o.test/a.jpg?w=1&" <> name <> "=" <> secret
    end
  end

  defp tail_of(name), do: binary_part(name, 1, byte_size(name) - 1)

  # A presigned URL in each spelling a client might put in one segment.
  defp encoded_url(secret) do
    gen all(
          url <- presigned_url(secret),
          spelling <-
            member_of([:escaped, :base64url, :base64url_padded, :base64, :base64_escaped])
        ) do
      case spelling do
        :escaped -> URI.encode_www_form(url)
        :base64url -> Base.url_encode64(url, padding: false)
        :base64url_padded -> Base.url_encode64(url)
        :base64 -> Base.encode64(url)
        :base64_escaped -> URI.encode_www_form(Base.encode64(url))
      end
    end
  end

  defp option_segment(secret) do
    one_of([
      member_of(["w=40", "rs=fill:10:10", "-", "sig=AbC", "wm-enc=AQRTMotB"]),
      map(encoded_url(secret), &("wm-src64=" <> &1))
    ])
  end

  defp tail_segment(secret) do
    one_of([
      member_of(["a.jpg", "https:", "", "o.test", "src", "src64"]),
      presigned_url(secret),
      encoded_url(secret),
      map(encoded_url(secret), &("wm-src64=" <> &1))
    ])
  end

  defp query(secret) do
    one_of([
      constant(""),
      map(presigned_url(secret), fn url -> url |> String.split("?") |> List.last() end)
    ])
  end

  # The secret in any spelling the output could hold: as is, percent-encoded,
  # or inside a base64 token.
  defp refute_secret(output, secret) do
    refute output =~ secret

    for piece <- String.split(output, ["/", "=", "?", "&", ";"]),
        piece = URI.decode(piece),
        decode <- [&Base.url_decode64(&1, padding: false), &Base.url_decode64/1, &Base.decode64/1],
        {:ok, decoded} <- [decode.(piece)] do
      refute decoded =~ secret
    end
  end
end
