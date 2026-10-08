defmodule ImagePipe.Source.AuthTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ImagePipe.Source.Auth

  defp freeze(path), do: Auth.freeze([auth: {:netrc, path}], "https://origin.test/cat.jpg")[:auth]

  test "a netrc file supplies the host's credentials", %{tmp_dir: dir} do
    path = Path.join(dir, "netrc")

    File.write!(
      path,
      "machine other.test login x password y\nmachine origin.test login u password p\n"
    )

    assert freeze(path) == {:basic, "u:p"}
    assert Auth.freeze([auth: {:netrc, path}], "https://unknown.test/cat.jpg")[:auth] == nil
  end

  test "a changed netrc file is read again", %{tmp_dir: dir} do
    path = Path.join(dir, "netrc")
    File.write!(path, "machine origin.test login u password p\n")
    assert freeze(path) == {:basic, "u:p"}

    File.write!(path, "machine origin.test login u password rotated\n")
    File.touch!(path, System.os_time(:second) + 5)

    # Expire the once-a-second check instead of waiting it out.
    {_identity, _parsed, checked} = :persistent_term.get({Auth, :netrc, path})
    :atomics.put(checked, 1, System.monotonic_time(:millisecond) - 60_000)

    assert freeze(path) == {:basic, "u:rotated"}
  end

  test "a missing netrc file fails", %{tmp_dir: dir} do
    assert_raise RuntimeError, ~r/error reading .netrc file/, fn ->
      freeze(Path.join(dir, "missing"))
    end
  end
end
