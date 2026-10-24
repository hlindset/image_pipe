defmodule ImagePipe.Telemetry.SourceURLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Telemetry

  describe "source_url/1" do
    test "redacts every query value and keeps the names" do
      assert Telemetry.source_url(
               "https://o.test/a.jpg?X-Amz-Signature=s&token=t;hdnts=exp~1&v=2&empty="
             ) ==
               "https://o.test/a.jpg?X-Amz-Signature=REDACTED&token=REDACTED;" <>
                 "hdnts=REDACTED&v=REDACTED&empty=REDACTED"
    end

    test "redacts a query component without a value, which can be a token" do
      assert Telemetry.source_url("https://o.test/a.jpg?sig=1&s3cr3t&&v") ==
               "https://o.test/a.jpg?sig=REDACTED&REDACTED&&REDACTED"
    end

    test "reads the query as the origin does" do
      # A name after a second `?` is part of the value before it.
      assert Telemetry.source_url("https://o.test/a.jpg?a=b?sig=s") ==
               "https://o.test/a.jpg?a=REDACTED"

      # A fragment isn't part of the query.
      assert Telemetry.source_url("https://o.test/a.jpg#sig=s") == "https://o.test/a.jpg#sig=s"

      assert Telemetry.source_url("https://o.test/a.jpg?sig=s#sig=t") ==
               "https://o.test/a.jpg?sig=REDACTED#sig=t"
    end

    test "redacts userinfo" do
      assert Telemetry.source_url("https://user:pass@o.test/a.jpg") ==
               "https://REDACTED@o.test/a.jpg"

      assert Telemetry.source_url("//user@o.test/a@b.jpg") == "//REDACTED@o.test/a@b.jpg"
      assert Telemetry.source_url("https://a@b@o.test") == "https://REDACTED@o.test"
      assert Telemetry.source_url("photos/a@2x.jpg") == "photos/a@2x.jpg"
      assert Telemetry.source_url("photos//a@2x.jpg") == "photos//a@2x.jpg"
      assert Telemetry.source_url("1http://user@o.test/a.jpg") == "1http://user@o.test/a.jpg"
    end

    test "gives valid UTF-8 with control characters percent-encoded" do
      assert Telemetry.source_url(<<"a", 0xFF, ".jpg">>) == "a\uFFFD.jpg"

      assert Telemetry.source_url("a.jpg\n[error] GET /x\r\t\x7F") ==
               "a.jpg%0A[error] GET /x%0D%09%7F"
    end

    test "keeps sources without a query or userinfo as they are" do
      for source <- ["photos/cat.jpg", "https://o.test/a.jpg#top", "s3://bucket/key.png"] do
        assert Telemetry.source_url(source) == source
      end
    end

    property "keeps every name and redacts every value" do
      check all(
              base <- member_of(["https://o.test/a.jpg", "photos/a.jpg", "//o.test/b"]),
              params <-
                list_of(
                  tuple({string(:alphanumeric, min_length: 1), string(:alphanumeric)}),
                  min_length: 1,
                  max_length: 6
                )
            ) do
        query = Enum.map_join(params, "&", fn {name, value} -> name <> "=" <> value end)
        expected = Enum.map_join(params, "&", fn {name, _value} -> name <> "=REDACTED" end)

        assert Telemetry.source_url(base <> "?" <> query) == base <> "?" <> expected
      end
    end

    test "work per byte stays within a small constant" do
      source = "https://o.test/a.jpg?" <> String.duplicate("sig=a&", 1_600)

      {:reductions, before} = Process.info(self(), :reductions)
      Telemetry.source_url(source)
      {:reductions, later} = Process.info(self(), :reductions)

      assert later - before < 100 * byte_size(source)
    end
  end
end
