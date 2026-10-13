defmodule ImagePipe.CacheCostEvictionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Test.Caches

  setup do
    root = Path.join(System.tmp_dir!(), "cost_eviction_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    media = Path.join(root, "media")
    File.mkdir_p!(media)

    File.cp!(
      Application.app_dir(:image_pipe, "priv/static/images/woman.jpg"),
      Path.join(media, "woman.jpg")
    )

    sources = [
      media: [adapter: ImagePipe.Source.File, match: :path, options: [root: media, root_id: "m"]]
    ]

    prefix = [:"cost_eviction_#{System.unique_integer([:positive])}"]
    test_pid = self()

    :telemetry.attach(
      "#{inspect(prefix)}",
      prefix ++ [:cache, :write, :stop],
      &__MODULE__.handle_write/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach("#{inspect(prefix)}") end)
    %{root: root, sources: sources, prefix: prefix}
  end

  test "an autoquality image outlasts plain renders requested as often", ctx do
    cache_root = Path.join(ctx.root, "cache")
    sizing = start(ctx, Path.join(ctx.root, "sizing"), 1_000_000_000)
    {_key, searched_bytes} = render(sizing, searched("size"))
    {_key, plain_bytes} = render(sizing, plain("size"))

    # Room for the searched image and 24 plain ones, so the next plain one has
    # to evict. A writer holds at most a twentieth of the cap, so the cache
    # needs that many entries for each to be written.
    cache = start(ctx, cache_root, searched_bytes + 24 * plain_bytes)
    {searched_key, _bytes} = render(cache, searched("a"))
    plain_keys = for n <- 1..24, do: cache |> render(plain("p#{n}")) |> elem(0)

    # The next one is rejected until it has been requested more often than
    # the entry it would evict.
    next_key = render_until_stored(cache, plain("next"), 5)

    assert stored?(cache_root, searched_key)
    assert stored?(cache_root, next_key)
    assert Enum.count(plain_keys, &stored?(cache_root, &1)) < 24
  end

  # Source records are written too, without an estimate.
  def handle_write(_event, _measurements, %{estimated_cost_us: _cost} = meta, test_pid),
    do: send(test_pid, {:written, meta.cache_key, meta.cache, meta.bytes})

  def handle_write(_event, _measurements, _meta, _test_pid), do: :ok

  defp start(ctx, root, max_size_bytes) do
    name = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")

    start_supervised!(
      {ImagePipe,
       name: name,
       sources: ctx.sources,
       telemetry_prefix: ctx.prefix,
       cache: [root: root, max_size_bytes: max_size_bytes]},
      id: name
    )

    {name, root}
  end

  defp searched(cachebuster),
    do: {cachebuster, [resize: [width: 200]], [format: :avif, autoquality: true]}

  defp plain(cachebuster), do: {cachebuster, [resize: [width: 200]], [format: :jpeg]}

  defp render({name, root}, {cachebuster, group, output}) do
    builder =
      ImagePipe.URL.new(ImagePipe.url_config(name), cachebuster: cachebuster)
      |> ImagePipe.URL.group(group)
      |> ImagePipe.URL.output(output)

    assert {:ok, _result} = ImagePipe.run(name, builder, {:source, "woman.jpg"})
    Caches.await_writes(cache: [root: root])
    assert_receive {:written, key, _cache, bytes}
    {key, bytes}
  end

  defp render_until_stored(cache, request, tries) when tries > 0 do
    {key, _bytes} = render(cache, request)
    {_name, root} = cache
    if stored?(root, key), do: key, else: render_until_stored(cache, request, tries - 1)
  end

  defp stored?(root, key) do
    {:ok, paths} = FileSystem.paths_from_hash(key, root: root)
    File.exists?(paths.meta_path)
  end
end
