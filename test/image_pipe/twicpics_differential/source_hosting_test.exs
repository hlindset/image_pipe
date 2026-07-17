defmodule ImagePipe.TwicpicsDifferential.SourceHostingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.TwicpicsDifferential.SourceHosting

  @moduletag :tmp_dir

  @direct_url "https://files.catbox.moe/source.png"
  @hosted_url "https://imagepipe.twic.pics/source.png"
  @identity_url @hosted_url <> "?twic=v1/output=png"

  setup %{tmp_dir: tmp_dir} do
    source = png(4, 4, [10, 20, 30, 255], 4)
    path = Path.join(tmp_dir, "source.png")
    File.write!(path, source)

    %{path: path, source: source}
  end

  test "returns a verified source record for complete inventory metadata", context do
    env = env(context.source, context.source)

    assert SourceHosting.resolve!(entry(), context.path, env) == %{
             hosted_url: @hosted_url,
             sha256: sha256(context.source)
           }

    assert_receive {:fetch, @direct_url}
    assert_receive {:fetch, @identity_url}
    refute_receive _
  end

  test "uploads once and aborts when both inventory URLs are absent", context do
    env = env(context.source, context.source)
    path = context.path

    assert_raise Mix.Error, ~r/record both URLs in SourceInventory/, fn ->
      SourceHosting.resolve!(entry(hosted_url: nil, source_bytes_url: nil), context.path, env)
    end

    assert_receive {:upload, ^path, %{file: "source.png"}}
    assert_receive {:info, "source_bytes_url: \"#{@direct_url}\""}
    assert_receive {:info, "hosted_url: \"#{@hosted_url}\""}
    refute_receive {:fetch, _}
  end

  test "rejects a half-complete inventory before upload or fetch", context do
    for incomplete <- [
          entry(source_bytes_url: nil),
          entry(hosted_url: nil)
        ] do
      assert_raise Mix.Error, ~r/incomplete source-hosting metadata/, fn ->
        SourceHosting.resolve!(incomplete, context.path, env(context.source, context.source))
      end
    end

    refute_receive {:upload, _, _}
    refute_receive {:fetch, _}
  end

  test "rejects direct hosted bytes that differ from the committed source", context do
    assert_raise Mix.Error, ~r/hosted bytes.*differ from committed/, fn ->
      SourceHosting.resolve!(entry(), context.path, env("different", context.source))
    end

    assert_receive {:fetch, @direct_url}
    refute_receive {:fetch, @identity_url}
  end

  test "rejects invalid URL structure and mismatched object basenames", context do
    invalid_pairs = [
      {"http://files.catbox.moe/source.png", @hosted_url},
      {"https://other.example/source.png", @hosted_url},
      {@direct_url, "https://other.example/source.png"},
      {"https://user@files.catbox.moe/source.png", @hosted_url},
      {"https://files.catbox.moe:444/source.png", @hosted_url},
      {"https://files.catbox.moe/source.png?x=1", @hosted_url},
      {@direct_url, "https://imagepipe.twic.pics/source.png#fragment"},
      {@direct_url, "https://imagepipe.twic.pics/other.png"},
      {"https://files.catbox.moe/", "https://imagepipe.twic.pics/"}
    ]

    for {direct_url, hosted_url} <- invalid_pairs do
      invalid = entry(source_bytes_url: direct_url, hosted_url: hosted_url)

      assert_raise Mix.Error, ~r/invalid source-hosting URL pair/, fn ->
        SourceHosting.resolve!(invalid, context.path, env(context.source, context.source))
      end
    end

    refute_receive {:fetch, _}
  end

  test "rejects hosted identity renders with different dimensions, bands, or pixels", context do
    invalid_identities = [
      png(3, 4, [10, 20, 30, 255], 4),
      png(4, 4, [10, 20, 30], 3),
      png(4, 4, [90, 80, 70, 255], 4)
    ]

    for identity <- invalid_identities do
      assert_raise Mix.Error, ~r/TwicPics identity render differs from committed source/, fn ->
        SourceHosting.resolve!(entry(), context.path, env(context.source, identity))
      end
    end
  end

  test "propagates upload failure without fetching either URL", context do
    test_pid = self()
    path = context.path

    upload_failure = %{
      env(context.source, context.source)
      | upload: fn path, source_entry ->
          send(test_pid, {:upload, path, source_entry})
          raise "upload failed"
        end
    }

    assert_raise RuntimeError, "upload failed", fn ->
      SourceHosting.resolve!(
        entry(hosted_url: nil, source_bytes_url: nil),
        context.path,
        upload_failure
      )
    end

    assert_receive {:upload, ^path, _}
    refute_receive {:fetch, _}
  end

  defp entry(overrides \\ []) do
    Map.merge(
      %{
        file: "source.png",
        hosted_url: @hosted_url,
        source_bytes_url: @direct_url
      },
      Map.new(overrides)
    )
  end

  defp env(direct_body, identity_body) do
    test_pid = self()

    %{
      upload: fn path, source_entry ->
        send(test_pid, {:upload, path, source_entry})
        {@direct_url, @hosted_url}
      end,
      fetch: fn url ->
        send(test_pid, {:fetch, url})
        fetch_body(url, direct_body, identity_body)
      end,
      info: fn message ->
        send(test_pid, {:info, message})
        :ok
      end
    }
  end

  defp fetch_body(@direct_url, direct_body, _identity_body), do: {:ok, direct_body}
  defp fetch_body(@identity_url, _direct_body, identity_body), do: {:ok, identity_body}
  defp fetch_body(url, _direct_body, _identity_body), do: {:error, {:unexpected_url, url}}

  defp png(width, height, color, bands) do
    width
    |> Image.new!(height, color: color, bands: bands)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
