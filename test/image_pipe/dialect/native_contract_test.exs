defmodule ImagePipe.Dialect.NativeContractTest.Mount do
  @moduledoc false
  # The contract kits drive a mountable `init/1` + `call/2` pair. Native now
  # mounts through `ImagePipe.Plug`'s dialect mode, so this shim is its
  # mount surface for the kits.

  def init(opts), do: ImagePipe.Plug.init([dialect: ImagePipe.Dialect.Native] ++ opts)
  def call(conn, config), do: ImagePipe.Plug.call(conn, config)
end

defmodule ImagePipe.Dialect.NativeContractTest do
  @moduledoc """
  The native dialect's `use`-site for `ImagePipe.ContractKit.CacheKey` and
  `ImagePipe.ContractKit.RequestSafety` [pipelines design §Enforcement
  model, layer 4]. Supplies concrete paths drawn from the Task 15-17 wire
  tests (`test/image_pipe/dialect/native_wire_test.exs`); the kits own
  request execution and assertions.
  """

  use ImagePipe.ContractKit.CacheKey, dialect: ImagePipe.Dialect.NativeContractTest.Mount
  use ImagePipe.ContractKit.RequestSafety, dialect: ImagePipe.Dialect.NativeContractTest.Mount

  @signing_key "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

  # ── ContractKit.CacheKey ─────────────────────────────────────────────────

  @impl ImagePipe.ContractKit.CacheKey
  def equivalent_requests(base_opts) do
    [
      # default `fit` (:contain) vs. its explicit spelling.
      {["/w=800/src/images/cat.jpg", "/fit=contain/w=800/src/images/cat.jpg"], base_opts},
      # default `anchor` (:center, once a guide consumer is present) vs. its
      # explicit spelling.
      {
        [
          "/crop=600,400/src/images/cat.jpg",
          "/crop=600,400/anchor=center/src/images/cat.jpg"
        ],
        base_opts
      },
      # `bg` color aliases (aqua/cyan) normalize to the same canonical sRGB
      # channel tuple (the full CSS Color Module Level 4 list).
      {["/bg=aqua/w=64/src/images/cat.jpg", "/bg=cyan/w=64/src/images/cat.jpg"], base_opts}
    ]
  end

  @impl ImagePipe.ContractKit.CacheKey
  def format_negotiation_cases(_base_opts) do
    %{
      same_selection: [
        # no-modern bucket: neither spelling names a modern format, so both
        # negotiate the `:source_negotiated` sentinel — load-bearing here.
        {"/w=64/src/images/cat.jpg", "image/jpeg", nil},
        # modern bucket: both select avif (webp only appears second).
        {"/w=64/src/images/cat.jpg", "image/avif", "image/avif,image/webp"}
      ],
      different_selection: [
        {"/w=64/src/images/cat.jpg", "image/avif", nil}
      ],
      explicit_format: [
        {"/format=webp/w=64/src/images/cat.jpg", "image/avif"}
      ],
      fixed_content_type: [
        "/w=32/output=blurhash/src/images/cat.jpg"
      ]
    }
  end

  @impl ImagePipe.ContractKit.CacheKey
  def storage_only_case(base_opts) do
    opts = Keyword.put(base_opts, :storage_inputs, [{:header, "x-tenant"}])

    variants = [
      {:header, "x-tenant", "team-a"},
      {:header, "x-tenant", "team-b"}
    ]

    {"/w=64/src/images/cat.jpg", opts, variants}
  end

  # ── ContractKit.RequestSafety ────────────────────────────────────────────

  @impl ImagePipe.ContractKit.RequestSafety
  def rejectable_requests(_base_opts) do
    [
      {"/bogus=10/src/images/cat.jpg", 400},
      {"/w=invalid/src/images/cat.jpg", 400},
      {"/w=800/w=900/src/images/cat.jpg", 400},
      {"/crop=100,100/region=0,0,10,10/src/images/cat.jpg", 400},
      {"/w=800/then/then/w=900/src/images/cat.jpg", 400},
      {"/w=64/src/images/cat.jpg?x=1", 400},
      # Signature verification (§Signing) runs before any parsing, on a
      # keyed instance: missing sig= and an invalid sig= both reject with
      # 403 before the source or cache are ever touched.
      {"/w=64/src/images/cat.jpg", 403, [keys: [@signing_key]]},
      {"/sig=" <> String.duplicate("A", 43) <> "/w=64/src/images/cat.jpg", 403,
       [keys: [@signing_key]]},
      # The `expires` gate (§Signing) runs before source resolve: a past
      # timestamp rejects with 404 before the source or cache are touched.
      {"/expires=#{System.os_time(:second) - 3600}/w=64/src/images/cat.jpg", 404}
    ]
  end

  @impl ImagePipe.ContractKit.RequestSafety
  def valid_request(_base_opts), do: "/w=64/src/images/cat.jpg"
end
