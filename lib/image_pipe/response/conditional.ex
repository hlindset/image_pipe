defmodule ImagePipe.Response.Conditional do
  @moduledoc false
  # Conditional-GET (`If-None-Match`) evaluation, usable BEFORE any cache
  # lookup or source fetch — a dialect's `ETag` is derived purely from
  # request-identity material (see `ImagePipe.Representation`), so it exists
  # the moment a representation is built, before the cache is ever consulted.
  #
  # This deliberately duplicates the private `If-None-Match` parsing/matching
  # helpers in `ImagePipe.Request.HTTPCache` (`if_none_match?/2`,
  # `parse_if_none_match/1`, and the public `if_none_match_wildcard?/1`)
  # rather than sharing them: `HTTPCache` is `Request`-boundary, framework-
  # frozen code, and this module must stay reachable from a dialect (the
  # `Response` boundary) without depending on `Request`. See the Task 16
  # report and the `.credo.exs` `ExDNA.Credo` `ignore:` entry for this file,
  # which follows the same precedent as Task 12/15's Decode/Delivery
  # duplications.

  import Plug.Conn, only: [get_req_header: 2]

  @doc """
  Whether `conn` carries an `If-None-Match` precondition that matches `etag`,
  for GET/HEAD requests only.

  Mirrors `ImagePipe.Request.HTTPCache.evaluate_conditional/3`'s matching
  semantics (comma-separated tag list, weak `W/"..."` prefixes stripped
  before comparison) but is a plain predicate over `conn` and a known `etag`
  — it does not build cache/representation identity itself, so it can run
  before any cache lookup.

  A bare `*` wildcard does NOT match here: per RFC 9110 §13.1.2, `*` may only
  short-circuit once a current representation is *proven* to exist, and
  nothing is proven pre-fetch. See `if_none_match_wildcard?/1` for the
  post-cache-hit re-check.
  """
  @spec not_modified?(Plug.Conn.t(), String.t() | nil) :: boolean()
  def not_modified?(%Plug.Conn{method: method} = conn, etag)
      when method in ["GET", "HEAD"] and is_binary(etag) do
    if_none_match?(conn, etag)
  end

  def not_modified?(%Plug.Conn{}, _etag), do: false

  @doc """
  Whether the request carried an `If-None-Match: *` wildcard precondition.

  Only meaningful once a current representation is proven to exist (a cache
  hit) — see the module doc and `not_modified?/2`. A header mixing `*` with
  explicit tags collapses to the wildcard, since `*` ("match any current
  representation") subsumes any specific tag.
  """
  @spec if_none_match_wildcard?(Plug.Conn.t()) :: boolean()
  def if_none_match_wildcard?(%Plug.Conn{} = conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.join(",")
    |> parse_if_none_match() == :wildcard
  end

  defp if_none_match?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.join(",")
    |> parse_if_none_match()
    |> tags_match?(etag)
  end

  defp parse_if_none_match(""), do: []

  defp parse_if_none_match(value) do
    tags =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if "*" in tags, do: :wildcard, else: tags
  end

  defp tags_match?(:wildcard, _etag), do: false
  defp tags_match?(tags, etag), do: Enum.any?(tags, &weak_entity_match?(&1, etag))

  defp weak_entity_match?(candidate, etag),
    do: quoted_entity_tag?(candidate) and strip_weak(candidate) == strip_weak(etag)

  defp quoted_entity_tag?("W/\"" <> rest), do: String.ends_with?(rest, "\"")
  defp quoted_entity_tag?("\"" <> rest), do: String.ends_with?(rest, "\"")
  defp quoted_entity_tag?(_value), do: false

  defp strip_weak("W/" <> rest), do: rest
  defp strip_weak(value), do: value
end
