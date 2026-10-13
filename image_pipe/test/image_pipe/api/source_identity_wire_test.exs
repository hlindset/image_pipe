defmodule ImagePipe.API.SourceIdentityWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.IdentitySource
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.Caches
  alias Vix.Vips.Image, as: VipsImage

  defmodule SwitchableSource do
    # IdentitySource with its seed and bytes read from an Agent, so one
    # mount can serve a changed original.
    @moduledoc false
    @behaviour ImagePipe.Source

    @impl true
    def identifiers(opts), do: IdentitySource.identifiers(opts)

    @impl true
    def validate_options(opts), do: {:ok, opts}

    @impl true
    def resolve(source, opts, runtime), do: IdentitySource.resolve(source, current(opts), runtime)

    @impl true
    def fetch(resolved, opts, runtime), do: IdentitySource.fetch(resolved, current(opts), runtime)

    defp current(opts), do: Keyword.merge(opts, Agent.get(Keyword.fetch!(opts, :state), & &1))
  end

  test "distinct map and list byte seeds do not reuse cached pixels or return false 304" do
    {config, state} = mount(%{revision: 1}, :red)

    first = request(config)
    assert first.status == 200
    assert_receive :identity_source_fetch
    assert [first_hash] = Enum.uniq(CacheObserver.lookup_hashes())

    switch(state, [revision: 1], :blue)
    second = request(config)
    assert second.status == 200
    assert_receive :identity_source_fetch
    assert [second_hash] = Enum.uniq(CacheObserver.lookup_hashes())
    refute first_hash == second_hash
    refute pixels(first) == pixels(second)
    refute get_resp_header(first, "etag") == get_resp_header(second, "etag")

    [old_etag] = get_resp_header(first, "etag")
    conditional = request(config, old_etag)
    assert conditional.status == 200
    assert conditional.resp_body == second.resp_body
    refute_received :identity_source_fetch

    [current_etag] = get_resp_header(second, "etag")
    _ = CacheObserver.lookup_hashes()
    assert request(config, current_etag).status == 304
    assert CacheObserver.lookup_hashes() == []
    refute_received :identity_source_fetch
  end

  test "a structured byte seed supports conditional requests" do
    {config, _state} = mount(~D[2026-09-23], :red)
    first = request(config)
    assert first.status == 200
    assert_receive :identity_source_fetch
    [etag] = get_resp_header(first, "etag")
    assert request(config, etag).status == 304
    refute_received :identity_source_fetch
  end

  defp mount(seed, color) do
    state = start_supervised!({Agent, fn -> nil end})
    switch(state, seed, color)

    config =
      [
        sources: [
          path: [
            adapter: SwitchableSource,
            match: :path,
            options: [state: state, owner: self()]
          ]
        ]
      ]
      |> CacheObserver.observe()
      |> Caches.plug()

    {config, state}
  end

  defp switch(state, seed, color) do
    {:ok, image} = Image.new(8, 8, color: color)
    {:ok, bytes} = Image.write(image, :memory, suffix: ".png")
    Agent.update(state, fn _ -> [seed: seed, bytes: bytes] end)
  end

  defp request(config, etag \\ nil) do
    conn = conn(:get, "/format=png/src/photo.png")
    conn = if etag, do: put_req_header(conn, "if-none-match", etag), else: conn
    ImagePipe.Plug.call(conn, config)
  end

  defp pixels(conn) do
    {:ok, image} = Image.from_binary(conn.resp_body)
    {:ok, pixels} = VipsImage.write_to_binary(image)
    pixels
  end
end
