defmodule ImagePipe.Dialect.ImgproxyContractTest do
  @moduledoc """
  The imgproxy dialect's `use`-site for `ImagePipe.ContractKit.CacheKey` and
  `ImagePipe.ContractKit.RequestSafety` [pipelines design §Enforcement model,
  layer 4]. Supplies concrete paths in imgproxy's wire syntax (drawn from
  `test/image_pipe/imgproxy_wire_conformance_test.exs`); the kits own request
  execution and assertions.

  Sources are the wire suite's relative `plain/images/beach.jpg` form, resolved
  against the kit's own `RootHTTPAdapter` origin wiring.
  """

  use ImagePipe.ContractKit.CacheKey, dialect: ImagePipe.Dialect.Imgproxy
  use ImagePipe.ContractKit.RequestSafety, dialect: ImagePipe.Dialect.Imgproxy

  # Hex-encoded "test-key" / "test-salt", the wire suite's signing pair.
  @signing_keys ["746573742d6b6579"]
  @signing_salts ["746573742d73616c74"]

  # ── ContractKit.CacheKey ─────────────────────────────────────────────────

  @impl ImagePipe.ContractKit.CacheKey
  def equivalent_requests(base_opts) do
    [
      # `rs:` shorthand vs. its `w:`/`h:`/`rt:` longhand spelling.
      {
        [
          "/unsafe/rs:fit:100:100/plain/images/beach.jpg",
          "/unsafe/w:100/h:100/rt:fit/plain/images/beach.jpg"
        ],
        base_opts
      },
      # Option ORDER must not affect identity: the native API is declarative, so
      # URL option order never defines processing order.
      {
        [
          "/unsafe/w:100/h:80/plain/images/beach.jpg",
          "/unsafe/h:80/w:100/plain/images/beach.jpg"
        ],
        base_opts
      },
      # A preset and its inline expansion are the same request.
      {
        [
          "/unsafe/pr:thumb/plain/images/beach.jpg",
          "/unsafe/rs:fit:100:100/plain/images/beach.jpg"
        ],
        Keyword.put(base_opts, :presets, %{"thumb" => "rs:fit:100:100"})
      }
    ]
  end

  @impl ImagePipe.ContractKit.CacheKey
  def format_negotiation_cases(_base_opts) do
    %{
      same_selection: [
        # no-modern bucket: neither spelling names a modern format, so both
        # negotiate the `:source_negotiated` sentinel.
        {"/unsafe/w:64/plain/images/beach.jpg", "image/jpeg", nil},
        # modern bucket: both select avif (webp only appears second).
        {"/unsafe/w:64/plain/images/beach.jpg", "image/avif", "image/avif,image/webp"}
      ],
      different_selection: [
        {"/unsafe/w:64/plain/images/beach.jpg", "image/avif", nil}
      ],
      explicit_format: [
        {"/unsafe/f:webp/w:64/plain/images/beach.jpg", "image/avif"}
      ],
      # `/info` is imgproxy's fixed terminal: JSON out, no format to select and
      # so nothing to vary on (see `Dialect.Imgproxy`'s `@info_negotiation`).
      fixed_content_type: [
        "/info/unsafe/plain/images/beach.jpg"
      ]
    }
  end

  @impl ImagePipe.ContractKit.CacheKey
  def storage_only_case(base_opts) do
    # NOTE: the brief proposed a `cb:v1`/`cb:v2` cachebuster pair here. The kit's
    # variant type is `{:header | :cookie, name, value}` and it applies variants as
    # request headers/cookies — a URL-option cachebuster cannot be expressed through
    # it. A configured storage-only header carries the same contract the kit asserts
    # (differing keys, equal ETag), so this mirrors native's header shape.
    opts = Keyword.put(base_opts, :storage_inputs, [{:header, "x-tenant"}])

    variants = [
      {:header, "x-tenant", "team-a"},
      {:header, "x-tenant", "team-b"}
    ]

    {"/unsafe/w:64/plain/images/beach.jpg", opts, variants}
  end

  # ── ContractKit.RequestSafety ────────────────────────────────────────────

  @impl ImagePipe.ContractKit.RequestSafety
  def rejectable_requests(base_opts) do
    signed_opts = [signature: [keys: @signing_keys, salts: @signing_salts]]

    [
      # Signature verification runs before any parsing: an invalid signature
      # rejects with 403 before the source or cache are touched.
      {"/invalid/w:120/plain/images/beach.jpg", 403, signed_opts},
      # Malformed option value.
      {"/unsafe/rs:bogus:1:1/plain/images/beach.jpg", 400},
      # Out-of-range option value.
      {"/unsafe/w:-1/plain/images/beach.jpg", 400},
      # Unknown option.
      {"/unsafe/bogus:10/plain/images/beach.jpg", 400},
      # No processing-options segment at all.
      {"/", 400},
      # The `exp:` gate: a past expiry rejects before source resolve.
      {"/unsafe/exp:100/plain/images/beach.jpg", 400,
       Keyword.put(base_opts, :clock, fn -> DateTime.from_unix!(101) end)}
    ]
  end

  @impl ImagePipe.ContractKit.RequestSafety
  def valid_request(_base_opts), do: "/unsafe/w:64/plain/images/beach.jpg"
end
