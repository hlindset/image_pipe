defmodule ImagePipe.TwicpicsDifferential.GenFixturesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [capture_io: 1]

  alias ImagePipe.Test.TwicpicsDifferential.SourceInventory
  alias Mix.Tasks.Twicpics.GenFixtures

  @moduletag :tmp_dir

  @sources_dir "test/support/image_pipe/test/twicpics_differential/sources"
  @fixtures_dir "test/support/image_pipe/test/twicpics_differential/fixtures"

  test "bootstrap inventory aborts before every downstream bake side effect", %{tmp_dir: tmp_dir} do
    source = source_fixture(tmp_dir, "bootstrap.png")

    env =
      task_env(
        [%{file: "bootstrap.png", hosted_url: nil, source_bytes_url: nil}],
        tmp_dir,
        source,
        source
      )

    assert_raise Mix.Error, ~r/record both URLs in SourceInventory/, fn ->
      GenFixtures.run_with([], env)
    end

    assert_receive {:upload, _, _}
    refute_downstream_events()
  end

  test "half-complete inventory ignores prior manifest URLs and aborts before downstream work", %{
    tmp_dir: tmp_dir
  } do
    source = source_fixture(tmp_dir, "grid_4x4.png")

    env =
      task_env(
        [
          %{
            file: "grid_4x4.png",
            hosted_url: nil,
            source_bytes_url: "https://files.catbox.moe/b7g72c.png"
          }
        ],
        tmp_dir,
        source,
        source
      )

    assert_raise Mix.Error, ~r/incomplete source-hosting metadata/, fn ->
      GenFixtures.run_with([], env)
    end

    refute_receive {:upload, _, _}
    refute_downstream_events()
  end

  test "identity mismatch aborts before fixture fetch, writes, report, or pruning", %{
    tmp_dir: tmp_dir
  } do
    source = source_fixture(tmp_dir, "source.png")
    identity = Image.new!(3, 4, color: [10, 20, 30, 255], bands: 4)
    identity = Image.write!(identity, :memory, suffix: ".png")

    env = task_env([complete_entry("source.png")], tmp_dir, source, identity)

    assert_raise Mix.Error, ~r/TwicPics identity render differs from committed source/, fn ->
      GenFixtures.run_with([], env)
    end

    assert_receive {:source_fetch, "https://files.catbox.moe/source.png"}
    assert_receive {:source_fetch, "https://imagepipe.twic.pics/source.png?twic=v1/output=png"}
    refute_downstream_events()
  end

  test "verifies every direct and TwicPics identity source before the first fixture request" do
    test_pid = self()
    entries = SourceInventory.all()

    source_hosting = %{
      upload: fn _, _ -> flunk("complete inventory must not upload") end,
      fetch: fn url ->
        send(test_pid, {:event, {:source_fetch, url}})
        {:ok, source_body(entries, url)}
      end,
      info: fn _ -> :ok end
    }

    env = %{
      source_entries: fn -> entries end,
      source_root: @sources_dir,
      source_hosting: source_hosting,
      fetch_oracle: fn constellation, _sources ->
        send(test_pid, {:event, {:fixture_fetch, constellation.id}})
        {File.read!(Path.join(@fixtures_dir, "#{constellation.id}.png")), "test"}
      end,
      write_fixture: fn _path, _body ->
        send(test_pid, {:event, :write_fixture})
        :ok
      end,
      write_manifest: fn _path, _manifest ->
        send(test_pid, {:event, :write_manifest})
        :ok
      end,
      write_report: fn _manifest ->
        send(test_pid, {:event, :write_report})
        :ok
      end,
      prune_orphans: fn _entries ->
        send(test_pid, {:event, :prune_orphans})
        :ok
      end
    }

    capture_io(fn -> GenFixtures.run_with(["--only", "focus_center_cover_wide"], env) end)

    events = drain_events([])

    assert events == [
             {:source_fetch, "https://files.catbox.moe/b7g72c.png"},
             {:source_fetch, "https://imagepipe.twic.pics/b7g72c.png?twic=v1/output=png"},
             {:source_fetch, "https://files.catbox.moe/tdkxst.webp"},
             {:source_fetch, "https://imagepipe.twic.pics/tdkxst.webp?twic=v1/output=png"},
             {:fixture_fetch, "focus_center_cover_wide"},
             :write_fixture,
             :prune_orphans,
             :write_manifest,
             :write_report
           ]
  end

  defp task_env(entries, source_root, direct_body, identity_body) do
    test_pid = self()

    %{
      source_entries: fn -> entries end,
      source_root: source_root,
      source_hosting: %{
        upload: fn path, entry ->
          send(test_pid, {:upload, path, entry})
          {"https://files.catbox.moe/#{entry.file}", "https://imagepipe.twic.pics/#{entry.file}"}
        end,
        fetch: fn url ->
          send(test_pid, {:source_fetch, url})

          case String.contains?(url, "?twic=") do
            true -> {:ok, identity_body}
            false -> {:ok, direct_body}
          end
        end,
        info: fn _message -> :ok end
      },
      fetch_oracle: fn _constellation, _sources ->
        send(test_pid, :fetch_oracle)
        flunk("fixture oracle must not run")
      end,
      write_fixture: fn _path, _body -> send(test_pid, :write_fixture) end,
      write_manifest: fn _path, _manifest -> send(test_pid, :write_manifest) end,
      write_report: fn _manifest -> send(test_pid, :write_report) end,
      prune_orphans: fn _entries -> send(test_pid, :prune_orphans) end
    }
  end

  defp source_fixture(tmp_dir, filename) do
    body =
      4
      |> Image.new!(4, color: [10, 20, 30, 255], bands: 4)
      |> Image.write!(:memory, suffix: ".png")

    File.write!(Path.join(tmp_dir, filename), body)
    body
  end

  defp complete_entry(filename) do
    %{
      file: filename,
      source_bytes_url: "https://files.catbox.moe/#{filename}",
      hosted_url: "https://imagepipe.twic.pics/#{filename}"
    }
  end

  defp source_body(entries, url) do
    entry = Enum.find(entries, &String.contains?(url, Path.basename(&1.hosted_url)))
    File.read!(Path.join(@sources_dir, entry.file))
  end

  defp refute_downstream_events do
    refute_receive {:source_fetch, _}
    refute_receive :fetch_oracle
    refute_receive :write_fixture
    refute_receive :write_manifest
    refute_receive :write_report
    refute_receive :prune_orphans
  end

  defp drain_events(events) do
    receive do
      {:event, event} -> drain_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
