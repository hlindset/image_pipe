defmodule ImagePipe.Cache.Entry do
  @moduledoc """
  Adapter-independent cached response entry.
  """

  alias ImagePipe.Debug.Info
  alias ImagePipe.Format

  @allowed_headers ~w(vary cache-control)
  @enforce_keys [:body, :content_type, :headers, :created_at]
  @header_name_pattern ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  @header_value_pattern ~r/^[^\x00-\x1F\x7F]*$/

  defstruct @enforce_keys ++ [debug: nil]

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          body: binary(),
          content_type: String.t(),
          headers: [header()],
          created_at: DateTime.t(),
          debug: Info.t() | nil
        }

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{body: body, content_type: content_type, headers: headers}) do
    with :ok <- validate_body(body),
         :ok <- validate_content_type(content_type),
         {:ok, _headers} <- cacheable_headers(headers) do
      :ok
    end
  end

  @doc false
  @spec validate_content_type(String.t()) :: :ok | {:error, term()}
  def validate_content_type(content_type) do
    case Format.format_from_mime_type(content_type) do
      {:ok, _format} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cacheable_headers(term()) :: {:ok, [header()]} | {:error, term()}
  def cacheable_headers(headers) when is_list(headers) do
    case Enum.reduce_while(headers, {:ok, []}, &normalize_header(&1, &2, headers)) do
      {:ok, normalized_headers} -> {:ok, Enum.reverse(normalized_headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  def cacheable_headers(headers), do: {:error, {:invalid_headers, headers}}

  defp validate_body(body) when is_binary(body), do: :ok
  defp validate_body(body), do: {:error, {:invalid_body, body}}

  defp normalize_header({name, value}, {:ok, normalized_headers}, headers)
       when is_binary(name) and is_binary(value) do
    if valid_header_name?(name) and valid_header_value?(value) do
      {:cont, {:ok, maybe_add_allowed_header(normalized_headers, String.downcase(name), value)}}
    else
      {:halt, {:error, {:invalid_headers, headers}}}
    end
  end

  defp normalize_header(_header, _acc, headers) do
    {:halt, {:error, {:invalid_headers, headers}}}
  end

  defp maybe_add_allowed_header(normalized_headers, name, value) do
    if name in @allowed_headers,
      do: [{name, value} | normalized_headers],
      else: normalized_headers
  end

  defp valid_header_name?(name), do: Regex.match?(@header_name_pattern, name)
  defp valid_header_value?(value), do: Regex.match?(@header_value_pattern, value)
end
