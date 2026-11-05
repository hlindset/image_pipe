defmodule ImagePipe.SettingsTest do
  # The settings are VM-wide, so these tests run alone and restore them.
  use ExUnit.Case, async: false

  alias ImagePipe.Execution.Staging
  alias ImagePipe.Settings

  @mb 1024 * 1024

  setup do
    on_exit(fn -> Settings.apply!(Application.get_all_env(:image_pipe)) end)
  end

  test "the defaults keep the system temporary directory and the budgets" do
    Settings.apply!([])

    assert Staging.dir() == Path.join(System.tmp_dir!(), "image_pipe")

    stats = ImagePipe.delivery_stats()
    assert {stats.max_buffered_bytes, stats.max_spooled_bytes} == {256 * @mb, 2048 * @mb}
  end

  @tag :tmp_dir
  test "the settings move the staging directory and set the budgets", %{tmp_dir: dir} do
    Settings.apply!(tmp_dir: dir, max_buffered_bytes: 8 * @mb, max_spooled_bytes: 0)

    stats = ImagePipe.delivery_stats()
    assert {stats.max_buffered_bytes, stats.max_spooled_bytes} == {8 * @mb, 0}
    assert is_integer(stats.buffered_bytes) and is_integer(stats.spooled_bytes)

    # A file a dead VM left in the configured directory is swept.
    staged = Path.join([dir, "image_pipe", ".image-pipe-left.tmp"])
    assert Staging.private_dir(Path.dirname(staged)) == :ok
    File.write!(staged, "x")
    File.touch!(staged, System.os_time(:second) - 7200)

    assert %{staged: 1} = Staging.sweep()
    refute File.exists?(staged)
  end

  @tag :tmp_dir
  test "invalid settings raise naming the setting", %{tmp_dir: dir} do
    for {settings, message} <- [
          {[max_spooled_bytes: -1], ~r/max_spooled_bytes/},
          {[max_buffered_bytes: "256"], ~r/max_buffered_bytes/},
          {[tmp_dir: Path.join(dir, "missing")], ~r/tmp_dir.*not a directory/},
          {[spool_dir: dir], ~r/spool_dir/}
        ] do
      assert_raise ArgumentError, message, fn -> Settings.apply!(settings) end
    end
  end
end
