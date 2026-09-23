defmodule ImagePipe.Cache.EntryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry

  test "adapter representation tags must agree with safe content types" do
    for {content_type, representation} <- [
          {"image/png", {:image, :jpeg}},
          {"image/png", {:image, :unknown}},
          {"image/png", :unknown},
          {"image/png;\rcharset=utf-8", nil},
          {"text/plain\n", {:complete_body, "text/plain\n"}},
          {"text/plain", {:complete_body, "application/json"}}
        ] do
      entry = %Entry{
        body: "cached bytes",
        content_type: content_type,
        representation: representation,
        headers: [],
        created_at: DateTime.utc_now()
      }

      assert {:error, _} = Entry.validate(entry)
    end
  end

  test "normalizes allowlisted response headers" do
    headers = [
      {"Vary", "Accept"},
      {"cache-control", "public, max-age=60"},
      {"connection", "close"},
      {"x-request-id", "abc123"}
    ]

    assert Entry.cacheable_headers(headers) ==
             {:ok, [{"vary", "Accept"}, {"cache-control", "public, max-age=60"}]}
  end

  test "preserves duplicate allowed headers in input order" do
    headers = [
      {"Vary", "Accept"},
      {"vary", "Origin"},
      {"Cache-Control", "public"},
      {"cache-control", "max-age=60"}
    ]

    assert Entry.cacheable_headers(headers) ==
             {:ok,
              [
                {"vary", "Accept"},
                {"vary", "Origin"},
                {"cache-control", "public"},
                {"cache-control", "max-age=60"}
              ]}
  end

  test "rejects malformed headers" do
    assert Entry.cacheable_headers(:not_headers) == {:error, {:invalid_headers, :not_headers}}

    assert Entry.cacheable_headers([{"vary", :not_binary}]) ==
             {:error, {:invalid_headers, [{"vary", :not_binary}]}}

    for invalid_header_value <- ["Accept\r\nSet-Cookie: session=1", "public\nmax-age=60", <<0>>] do
      headers = [{"Vary", invalid_header_value}]

      assert Entry.cacheable_headers(headers) == {:error, {:invalid_headers, headers}}
    end

    for invalid_header_name <- ["", "bad header", "vary:"] do
      headers = [{invalid_header_name, "value"}]

      assert Entry.cacheable_headers(headers) == {:error, {:invalid_headers, headers}}
    end
  end
end
