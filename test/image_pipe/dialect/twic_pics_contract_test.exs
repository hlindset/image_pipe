defmodule ImagePipe.Dialect.TwicPicsContractTest do
  @moduledoc """
  Instantiates the shared cache-key and request-safety contracts for the
  inverted TwicPics dialect.
  """

  use ImagePipe.ContractKit.CacheKey, dialect: ImagePipe.Dialect.TwicPics
  use ImagePipe.ContractKit.RequestSafety, dialect: ImagePipe.Dialect.TwicPics

  @impl ImagePipe.ContractKit.CacheKey
  def equivalent_requests(base_opts) do
    [
      {
        [
          "/images/cat.jpg?twic=v1/cover=1.5:2/resize=(700/2)/output=png",
          "/images/cat.jpg?twic=v1/cover=3:4/resize=350/output=png"
        ],
        base_opts
      }
    ]
  end

  @impl ImagePipe.ContractKit.CacheKey
  def format_negotiation_cases(_base_opts) do
    %{
      same_selection: [
        {"/images/cat.jpg?twic=v1/resize=64/output=auto", "image/jpeg", nil},
        # Both accept WebP; the dialect's auto negotiation selects WebP (AVIF is
        # off by default, matching hosted TwicPics), so both share one entry.
        {"/images/cat.jpg?twic=v1/resize=64/output=auto", "image/webp", "image/avif,image/webp"}
      ],
      different_selection: [
        # WebP-accepting -> WebP; no Accept -> source-negotiated. Distinct entries.
        {"/images/cat.jpg?twic=v1/resize=64/output=auto", "image/webp", nil}
      ],
      explicit_format: [
        {"/images/cat.jpg?twic=v1/resize=64/output=webp", "image/avif"}
      ],
      fixed_content_type: [
        "/images/cat.jpg?twic=v1/resize=64/output=png"
      ]
    }
  end

  @impl ImagePipe.ContractKit.CacheKey
  def storage_only_case(base_opts) do
    opts =
      Keyword.put(
        base_opts,
        :storage_inputs,
        [{:header, "x-tenant"}, {:cookie, "region"}]
      )

    variants = [
      {:header, "x-tenant", "team-a"},
      {:header, "x-tenant", "team-b"},
      {:cookie, "region", "eu"},
      {:cookie, "region", "us"}
    ]

    {"/images/cat.jpg?twic=v1/resize=64/output=png", opts, variants}
  end

  @impl ImagePipe.ContractKit.RequestSafety
  def rejectable_requests(_base_opts) do
    [
      {"/images/cat.jpg", 400},
      {"/images/cat.jpg?twic=v2/resize=64", 400},
      {"/images/cat.jpg?twic=v1/resize=(700/0)", 400},
      {"/images/cat.jpg?twic=v1/zoom=2", 400},
      {"/images/cat.jpg?twic=v1/focus=-50x-50/cover=100x100", 400},
      {"/images/cat.jpg?twic=v1/crop=0x100", 400}
    ]
  end

  @impl ImagePipe.ContractKit.RequestSafety
  def valid_request(_base_opts), do: "/images/cat.jpg?twic=v1/resize=64/output=png"
end
