defmodule ImagePipe.Cache.FileSystem.StoreNamesPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.FileSystem.Store

  property "a body filename parses back to its parts" do
    check all hash <- hex64(),
              body_sha256 <- hex64(),
              size <- non_negative_integer(),
              cost <- non_negative_integer() do
      name = Store.body_filename(hash, body_sha256, size, cost)
      row = {decode(hash), size, cost, decode(body_sha256)}

      assert {:ok,
              %{
                key_hash: ^hash,
                body_sha256: ^body_sha256,
                size_bytes: ^size,
                cost_us: ^cost,
                body_filename: ^name
              }} = Store.parse_body_filename(name)

      assert Store.body_row(name) == {:ok, row}
      assert Store.classify(name) == {:body, hash, row}
    end
  end

  property "a hash that isn't lowercase hex is rejected" do
    check all hash <- hex64(),
              body_sha256 <- hex64(),
              in_sha? <- boolean(),
              position <- integer(0..63),
              char <- member_of(~c"ABCDEFG.-+ /\0") do
      {hash, body_sha256} =
        if in_sha?,
          do: {hash, replace_at(body_sha256, position, char)},
          else: {replace_at(hash, position, char), body_sha256}

      name = Store.body_filename(hash, body_sha256, 10, 20)

      assert Store.parse_body_filename(name) == {:error, :invalid_body_filename}
      assert Store.body_row(name) == :error
      assert Store.classify(name) == :unrelated
    end
  end

  property "a size or cost that isn't plain digits is rejected" do
    check all hash <- hex64(),
              body_sha256 <- hex64(),
              digits <- string(?0..?9, min_length: 1),
              bad <- member_of(["", "-" <> digits, "+" <> digits, digits <> "x", "1.5", " 1"]),
              in_cost? <- boolean() do
      {size, cost} = if in_cost?, do: {digits, bad}, else: {bad, digits}
      name = "#{hash}.#{body_sha256}.#{size}.#{cost}.body"

      assert Store.parse_body_filename(name) == {:error, :invalid_body_filename}
      assert Store.body_row(name) == :error
      assert Store.classify(name) == :unrelated
    end
  end

  test "classifies metadata, temp, and digest-only body names" do
    hash = String.duplicate("a", 64)
    body_sha256 = String.duplicate("b", 64)

    assert Store.classify(hash <> ".meta") == {:meta, hash}
    assert Store.classify(".#{hash}.Ab_c-dE.tmp") == :temp
    assert Store.classify("#{hash}.#{body_sha256}.body") == {:body, hash, nil}

    for name <- [
          String.upcase(hash) <> ".meta",
          "notes.meta",
          ".#{hash}..tmp",
          ".#{hash}.a.b.tmp",
          ".image-pipe-Ab_c-dE.tmp",
          "#{hash}.#{String.upcase(body_sha256)}.body",
          "aa"
        ],
        do: assert(Store.classify(name) == :unrelated, name)
  end

  defp hex64, do: map(binary(length: 32), &Base.encode16(&1, case: :lower))

  defp decode(hex), do: Base.decode16!(hex, case: :lower)

  defp replace_at(string, position, char) do
    <<before::binary-size(^position), _old, rest::binary>> = string
    <<before::binary, char, rest::binary>>
  end
end
