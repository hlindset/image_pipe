defmodule ImagePipe.Plug.Request do
  @moduledoc false

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan.Request
  alias ImagePipe.Processing
  alias ImagePipe.Security
  alias ImagePipe.Source.Parser, as: SourceParser

  # Verify → lex → decrypt → parse. Returns the telemetry stop metadata with
  # the result so the Runner's parse span can report the signing key index.
  def parse(%Plug.Conn{} = conn, config) do
    {sig, signed_path} = Path.split_signature(conn)

    result =
      with {:ok, key_index} <- Security.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(conn) |> normalize_lex_error(),
           {:ok, lexed} <- decrypt_source(lexed, config),
           {:ok, request} <- Parser.parse(lexed, config) do
        {_marker, source, _span} = lexed.source
        {request, source, key_index}
      end

    case result do
      {%Request{} = request, source, key_index} ->
        {{:ok, request, source}, %{result: :ok, sig_key_index: key_index}}

      {:error, _reason} = error ->
        # Deliberately NO error tag — preserving the chain's parse stop shape.
        {error, %{result: :error}}
    end
  end

  def prepare(%Request{} = request, source, config, accept_header) do
    with {:ok, policy} <- Processing.prepare(request, config, accept_header),
         {:ok, plan_source} <- SourceParser.translate(source, config) do
      {:ok, plan_source, policy}
    end
  end

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  defp decrypt_source(%{source: {:enc, token, span}} = lexed, config) do
    case Security.decrypt_source(token, config) do
      {:ok, source} -> {:ok, %{lexed | source: {:enc, source, span}}}
      {:error, :invalid_concealed_source} = error -> error
    end
  end

  defp decrypt_source(lexed, _config), do: {:ok, lexed}
end
