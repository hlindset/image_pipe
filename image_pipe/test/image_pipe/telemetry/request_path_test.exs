defmodule ImagePipe.Telemetry.RequestPathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Telemetry

  @credentials ~w(X-Amz-Signature x-goog-credential sig AWSAccessKeyId)

  describe "work per byte" do
    # A path up to Bandit's 10,000-byte request line, built from one repeated
    # unit, each unit a `wm-src64=` token and the segments it could join.
    defp crafted(unit) do
      unit = "/wm-src64=AAA" <> unit
      String.duplicate(unit, div(10_000, byte_size(unit))) <> "/src/x.jpg"
    end

    test "stays within a small constant for crafted paths" do
      reaching = Base.encode64("https://a/b?sig=") |> binary_part(0, 20)

      paths = [
        crafted(String.duplicate("/AAAA", 64)),
        crafted(String.duplicate("/AAAA", 63) <> "/AAA="),
        crafted(String.duplicate("/AAAA", 63) <> "/A.jpg"),
        crafted("/A%3DA" <> String.duplicate("/AAAA", 62)),
        crafted(String.duplicate("/A%41A", 63) <> "/AA%3D"),
        crafted(String.duplicate("/A", 63) <> "/A.jpg"),
        crafted(String.duplicate("/A", 63) <> "/A="),
        crafted(String.duplicate("/A", 62) <> "/A%2B/A%3D"),
        String.duplicate("/wm-src64=" <> reaching <> String.duplicate("/AAA", 64), 7) <>
          "/src/x.jpg",
        String.duplicate("/wm-src64=A", 900) <> "/src/x.jpg",
        "/w=40/src64/" <> String.duplicate("A", 9_900),
        "/enc" <> String.duplicate("/src/a%3Fb", 900),
        "/enc/src/x" <> String.duplicate("%3Fa%3D", 1_400),
        "/enc" <> String.duplicate("/wm-src64=AAA" <> String.duplicate("/src64/AAAA", 32), 25),
        "/src" <> String.duplicate("/src64/AAAA", 800),
        "/enc" <> String.duplicate("/src64/A/src/x", 600),
        "/src/x" <> String.duplicate("/AAAA", 1_900) <> "/src/a%3Fsig%3D1"
      ]

      for path <- paths do
        assert reductions(fn -> Telemetry.request_path(path, "") end) < 100 * byte_size(path),
               binary_part(path, 0, 60)
      end
    end
  end

  describe "wm-src64 tokens split by `/`" do
    property "are redacted as decoding every joined candidate would" do
      check all(token <- presigned_token(), tail <- tail_segments()) do
        options = ["wm-src64=" <> token | tail]

        assert Telemetry.request_path(path(options), "") == path(expected(options))
      end
    end

    property "base64-looking segments without credentials are logged as sent" do
      check all(
              segments <- list_of(junk_segment(), min_length: 1, max_length: 70),
              tail <- tail_segments()
            ) do
        options = ["wm-src64=" <> Enum.join(segments, "/") | tail]

        assert Telemetry.request_path(path(options), "") == path(expected(options))
      end
    end
  end

  describe "a presigned source after another source marker" do
    test "is redacted when the path starts with enc or src64" do
      for marker <- ["enc", "src64"] do
        path = "/#{marker}/w=2/src/https%3A%2F%2Fo.test%2Fa.jpg%3FX-Amz-Signature%3Dsecret"

        assert Telemetry.request_path(path, "") ==
                 "/#{marker}/w=2/src/https://o.test/a.jpg?X-Amz-Signature=REDACTED"
      end
    end

    test "is redacted when a later marker splits a src URL or src64 token" do
      # Standard base64 of a presigned URL with a `/src/` segment.
      token = "aHR0cHM6Ly9vLnRlc3QvVSGY/src/Ejam4SqP1gtQW16LVNpZ25hdHVyZT1TRUNSRVRWQUxVRQ=="

      for path <- [
            "/enc/w=2/src/https://o.test/enc/a.jpg%3FX-Amz-Signature%3Dsecret",
            "/enc/w=2/src/https://o.test/src64/a.jpg%3FX-Amz-Signature%3Dsecret",
            "/enc/src/https://o.test/a%3Fx%3D1%26y%3D/src/%26X-Amz-Signature%3Dsecret",
            "/enc/src/https://o.test/a%3Fx%3D/src/https://o.test/b%3FX-Amz-Signature%3Dsecret",
            "/enc/w=2/src64/" <> token,
            "/src/x/src64/" <> token,
            "/w=2/wm-src64=" <> token <> "/src/x.jpg",
            "/enc/x/wm-src64=" <> String.replace(token, "/src/", "/src64/") <> "/y"
          ] do
        logged = Telemetry.request_path(path, "")

        refute logged =~ "secret", path
        refute logged =~ "Ejam4SqP1gtQW16", path
      end
    end

    test "is redacted from the query string a later src URL's `?` starts" do
      assert Telemetry.request_path("/w=2/src/https://o.test/a", "x=/src/b?X-Amz-Signature=s") ==
               "/w=2/src/https://o.test/a?x=/src/b?X-Amz-Signature=REDACTED"
    end

    property "never leaves its credential in the path" do
      check all(
              prefix <- list_of(prefix_segment(), max_length: 6),
              marker <- member_of(["src", "src64"]),
              url_path <- list_of(member_of(~w(src src64 enc a b.jpg)), max_length: 4),
              before <- member_of(["", "w=1&", "x=/src/&", "y=a/enc/b;", "z=1?"]),
              name <- member_of(@credentials),
              secret <-
                map(string(:alphanumeric, min_length: 4, max_length: 12), &("SeCrEt" <> &1)),
              spelling <- member_of([:escaped, :literal, :url, :standard])
            ) do
        # Only a later `src` source reads a name after a `?` in the query.
        before = if marker == "src64", do: String.replace(before, "?", "&"), else: before

        url =
          "https://o.test/" <> Enum.join(url_path, "/") <> "?" <> before <> name <> "=" <> secret

        source = source(marker, spelling, url)
        logged = Telemetry.request_path(path(prefix ++ [marker, source]), "")

        refute logged =~ secret
        refute logged =~ source
      end
    end
  end

  defp prefix_segment do
    member_of(
      ~w(w=2 rs=fill:10:10 src src64 enc AAAA Zm9v x.jpg https%3A%2F%2Fa.test%2Fb a%3Fx%3D a%3Fsig%3D1%26x%3D)
    )
  end

  defp source("src", :literal, url) do
    String.replace(url, ["?", "&", ";", "="], &("%" <> Base.encode16(&1)))
  end

  defp source("src", _spelling, url), do: URI.encode_www_form(url)
  defp source("src64", :url, url), do: Base.url_encode64(url, padding: false)
  defp source("src64", :standard, url), do: Base.encode64(url)
  defp source("src64", _spelling, url), do: URI.encode_www_form(Base.encode64(url))

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end

  # A presigned URL in standard base64, which holds `/`, in a spelling a
  # client might send. Bytes above 0x7F put a `/` at any offset, so a joined
  # prefix can decode too.
  defp presigned_token do
    gen all(
          path <-
            map(
              list_of(member_of([?a, ?z, ?~, ?>, ??, ?/, 0xBF, 0xFB, 0xFF]),
                min_length: 1,
                max_length: 60
              ),
              &:binary.list_to_bin/1
            ),
          name <- member_of(@credentials),
          value <- string(:alphanumeric, min_length: 1, max_length: 40),
          spelling <- member_of([:plain, :escaped, :extension, :python])
        ) do
      token = Base.encode64("https://b.example/" <> path <> "?" <> name <> "=" <> value)

      case spelling do
        :plain -> token
        :escaped -> URI.encode_www_form(token)
        :extension -> token <> ".jpg"
        :python -> token |> String.replace("+", "%2B") |> String.replace("=", "%3D")
      end
    end
  end

  defp junk_segment do
    one_of([
      filter(
        string([?A..?Z, ?a..?z, ?0..?9, ?+], min_length: 1, max_length: 8),
        &(&1 not in ~w(src src64 enc))
      ),
      map(string([?A..?Z, ?0..?9], min_length: 1, max_length: 4), &(&1 <> "%2B")),
      constant("AAA="),
      constant("A.jpg")
    ])
  end

  defp tail_segments do
    list_of(member_of(["w=40", "AAAA", "Zm9v", "rs=fill:10:10", "AB%3D", "%2F"]), max_length: 4)
  end

  # The redacted path from trying every candidate the way the redaction is
  # specified: the token alone, then joined with each following segment that
  # can continue it, in every spelling and base64 alphabet.
  defp path(options), do: Enum.map_join(options, &("/" <> &1)) <> "/src/a.jpg"

  defp expected(options) do
    ["wm-src64=" <> token | segments] = options |> Enum.join("/") |> String.split("/")

    case Enum.find(0..length(joinable(token, segments)), &presigned?([token | segments], &1)) do
      nil -> options
      taken -> ["wm-src64=REDACTED" | Enum.drop(segments, taken)]
    end
  end

  defp joinable(previous, [segment | rest]) do
    if previous =~ ~r/\A[A-Za-z0-9+%]+\z/ and segment =~ ~r/\A[A-Za-z0-9+%=.]+\z/,
      do: Enum.take([segment | joinable(segment, rest)], 64),
      else: []
  end

  defp joinable(_previous, []), do: []

  defp presigned?(segments, taken) do
    candidate = segments |> Enum.take(taken + 1) |> Enum.join("/")

    decoded =
      try do
        URI.decode(candidate)
      rescue
        ArgumentError -> candidate
      end

    for spelling <- [candidate, decoded],
        spelling <- [spelling, String.trim_trailing(spelling, "/")],
        spelling <- [spelling, String.replace(spelling, ~r/\.[A-Za-z0-9]+\z/, "")],
        decode <- [&Base.url_decode64(&1, padding: false), &Base.url_decode64/1, &Base.decode64/1],
        {:ok, url} <- [decode.(spelling)] do
      url
    end
    |> Enum.any?(&credential_query?/1)
  end

  defp credential_query?(url) do
    case String.split(url, "?", parts: 2) do
      [_base, query] ->
        query |> String.split(["&", ";"]) |> Enum.any?(&credential_pair?/1)

      [_base] ->
        false
    end
  end

  defp credential_pair?(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, value] -> credential?(name) and value != "REDACTED"
      [_name] -> false
    end
  end

  defp credential?(name) do
    decoded =
      try do
        URI.decode(name)
      rescue
        ArgumentError -> name
      end

    String.downcase(decoded) in ~w(awsaccesskeyid signature sig x-goog-signature
                                  x-goog-credential x-amz-signature x-amz-credential
                                  x-amz-security-token)
  end
end
