defmodule ImagePipe.Parser.TwicPics do
  @moduledoc """
  Parser for the TwicPics `?twic=v1/…` URL dialect.

  See `docs/twicpics_support_matrix.md` for the supported surface.
  """

  use Boundary,
    deps: [ImagePipe.Parser, ImagePipe.Plan, ImagePipe.Resolver, ImagePipe.Transform],
    exports: []

  @behaviour ImagePipe.Parser

  alias ImagePipe.Parser.TwicPics.Manipulation
  alias ImagePipe.Parser.TwicPics.Path
  alias ImagePipe.Parser.TwicPics.PlanBuilder
  alias ImagePipe.Plan.Output.QualitySearch

  # TwicPics has no host-level dialect options today; the full neutral surface is
  # honored, so the reject seam is a no-op.
  @supported_neutral :all

  @impl ImagePipe.Parser
  def validate_options!(opts) when is_list(opts) do
    twicpics = Keyword.get(opts, :twicpics, [])

    unless Keyword.keyword?(twicpics) do
      raise ArgumentError, "invalid twicpics options: expected a keyword list"
    end

    {neutral, unknown} = Keyword.split(twicpics, ImagePipe.Config.keys())

    unless unknown == [] do
      raise ArgumentError,
            "invalid twicpics config: unknown keys #{inspect(Keyword.keys(unknown))}"
    end

    neutral =
      neutral
      |> ImagePipe.Config.reject_unsupported!(@supported_neutral, "TwicPics")
      |> ImagePipe.Config.resolve!(twicpics_overlay())

    # Config-only dialect: surface a bad autoquality method/target at boot.
    case QualitySearch.from_config(neutral) do
      {:ok, _} -> :ok
      {:error, reason} -> raise ArgumentError, "invalid twicpics config: #{inspect(reason)}"
    end

    Keyword.put(opts, :twicpics, neutral)
  end

  defp twicpics_overlay, do: []

  @impl ImagePipe.Parser
  def parse(%Plug.Conn{} = conn, opts) do
    config = Keyword.fetch!(opts, :twicpics)

    with {:ok, source, manipulation} <- Path.extract(conn),
         {:ok, chain} <- Manipulation.parse(manipulation) do
      PlanBuilder.to_plan(source, chain, config)
    end
  end

  @impl ImagePipe.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end
end
