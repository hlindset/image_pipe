defmodule ImagePipe.Telemetry.SourceURLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Telemetry

  @credentials ~w(AWSAccessKeyId Signature sig X-Goog-Signature X-Goog-Credential
                  X-Amz-Signature X-Amz-Credential X-Amz-Security-Token)

  describe "source_url/1" do
    test "redacts credential values in any case and percent-encoding" do
      assert Telemetry.source_url(
               "https://o.test/a.jpg?X-Amz-Signature=s&x-amz-credential=k;%73ig=s&keep=1"
             ) ==
               "https://o.test/a.jpg?X-Amz-Signature=REDACTED&x-amz-credential=REDACTED;" <>
                 "%73ig=REDACTED&keep=1"
    end

    test "reads the query as the origin does" do
      # A name after a second `?` is part of the value before it.
      assert Telemetry.source_url("https://o.test/a.jpg?a=b?sig=s") ==
               "https://o.test/a.jpg?a=b?sig=s"

      # A fragment isn't part of the query.
      assert Telemetry.source_url("https://o.test/a.jpg#sig=s") == "https://o.test/a.jpg#sig=s"

      assert Telemetry.source_url("https://o.test/a.jpg?sig=s#sig=t") ==
               "https://o.test/a.jpg?sig=REDACTED#sig=t"
    end

    test "redacts userinfo" do
      assert Telemetry.source_url("https://user:pass@o.test/a.jpg") ==
               "https://REDACTED@o.test/a.jpg"

      assert Telemetry.source_url("//user@o.test/a@b.jpg") == "//REDACTED@o.test/a@b.jpg"
      assert Telemetry.source_url("photos/a@2x.jpg") == "photos/a@2x.jpg"
    end

    test "keeps sources without credentials as they are" do
      for source <- ["photos/cat.jpg", "https://o.test/a.jpg?w=1&h=2", "s3://bucket/key.png"] do
        assert Telemetry.source_url(source) == source
      end
    end

    property "changes only credential values" do
      check all(
              base <- member_of(["https://o.test/a.jpg", "photos/a.jpg", "//o.test/b"]),
              params <-
                list_of(
                  tuple(
                    {one_of([member_of(@credentials), string(?a..?z, min_length: 1)]),
                     string(:alphanumeric, min_length: 1)}
                  ),
                  min_length: 1,
                  max_length: 6
                ),
              cases <- list_of(member_of([:as_is, :downcased]), length: length(params))
            ) do
        pairs =
          Enum.zip_with(params, cases, fn {name, value}, spelling ->
            {if(spelling == :downcased, do: String.downcase(name), else: name), value}
          end)

        query = Enum.map_join(pairs, "&", fn {name, value} -> name <> "=" <> value end)

        expected =
          Enum.map_join(pairs, "&", fn {name, value} ->
            if String.downcase(name) in Enum.map(@credentials, &String.downcase/1),
              do: name <> "=REDACTED",
              else: name <> "=" <> value
          end)

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
