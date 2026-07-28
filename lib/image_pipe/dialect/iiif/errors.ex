defmodule ImagePipe.Dialect.IIIF.Errors do
  @moduledoc """
  Dialect-owned error → HTTP status mapping for the IIIF dialect.

  Grammar and identifier-resolution failures keep IIIF's terse vocabulary
  (404 `not found` / 400 `bad request`), and **any** unrecognized parse-phase
  rejection stays a 400: provenance rides the
  `%ImagePipe.Dialect.Failure{phase: :parse}` envelope, never a tag allowlist.

  Everything else routes through the shared `ImagePipe.Response.ErrorStatus`
  table, with the same core-stage rewraps every dialect performs: a transform
  failure becomes `{:transform_error, _}` (422), a materialization failure
  becomes `{:decode, _}` (415), and the `detector_required` gate becomes the
  plan-validation tag `{:detector_unavailable, :unavailable}` (422).

  A renderer failure arrives wrapped as `{:render, inner}`. `ErrorStatus`
  already recurses into `inner` for both status and message, so a render
  failure whose inner reason is a known family (source/decode/input limit)
  renders that family's status; anything it cannot classify renders 500
  `"error rendering response"`, distinguishing a render-terminal failure from
  an image-terminal one.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  require Logger

  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Response.ErrorStatus

  @grammar_tags [
    :invalid_region,
    :invalid_size,
    :invalid_rotation,
    :invalid_quality,
    :invalid_format
  ]

  @spec send(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, %Failure{phase: :parse, reason: reason}, config),
    do: send_parse(conn, reason, config)

  def send(%Plug.Conn{} = conn, {:plan_validation, reason}, config),
    do: resolve(conn, reason, config)

  def send(%Plug.Conn{} = conn, {:detector, :unavailable}, config),
    do: resolve(conn, {:detector_unavailable, :unavailable}, config)

  def send(%Plug.Conn{} = conn, {:render, reason} = full, config) do
    case ErrorStatus.classify(full) do
      :server_error ->
        Logger.error("render_error: #{inspect(reason)}")
        text(conn, 500, "error rendering response")

      _class ->
        resolve(conn, full, config)
    end
  end

  # A materialization failure is a decode failure (AGENTS.md); a pipeline
  # failure is unprocessable. Clause order matters — the materialize clause
  # must precede the general transform one.
  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}, config),
    do: resolve(conn, {:decode, reason}, config)

  def send(%Plug.Conn{} = conn, {:transform, inner}, config),
    do: resolve(conn, {:transform_error, inner}, config)

  def send(%Plug.Conn{} = conn, reason, config), do: resolve(conn, reason, config)

  defp send_parse(conn, :not_found, _config), do: text(conn, 404, "not found")

  defp send_parse(conn, {tag, _raw}, _config) when tag in @grammar_tags,
    do: text(conn, 400, "bad request")

  # Every other parse rejection — including a plan-building reject the grammar
  # cannot name — is a client error.
  defp send_parse(conn, _reason, _config), do: text(conn, 400, "bad request")

  defp resolve(conn, reason, config) do
    {status, message} = ErrorStatus.resolve_status(reason, config)
    text(conn, status, message)
  end

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
