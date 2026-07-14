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
  @content_type_pattern ~r{^[!#$%&'*+\-.^_`|~0-9A-Za-z]+/[!#$%&'*+\-.^_`|~0-9A-Za-z]+(\s*;.*)?$}

  defstruct @enforce_keys ++ [representation: nil, debug: nil]

  @type header :: {String.t(), String.t()}
  # `representation` tags what an entry's `content_type`/`body` mean:
  # `{:image, format}` for the framework's encoder-output path, or
  # `{:complete_body, content_type}` for a dialect-owned non-image complete
  # body (e.g. a BlurHash string). `nil` (the default for every entry
  # constructed before this widening, and for adapters — such as
  # `ImagePipe.Cache.FileSystem` — that don't yet persist the tag) is treated
  # identically to `{:image, _}`: `validate/1` falls back to the original
  # `Format`-based content-type check, so the `{:image, _}` path's behavior
  # is byte-for-byte unchanged.
  @type representation :: {:image, atom()} | {:complete_body, String.t()}
  @type t :: %__MODULE__{
          body: binary(),
          content_type: String.t(),
          headers: [header()],
          created_at: DateTime.t(),
          representation: representation() | nil,
          debug: Info.t() | nil
        }

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = entry) do
    with :ok <- validate_body(entry.body),
         :ok <- validate_content_type(entry.content_type, entry.representation),
         {:ok, _headers} <- cacheable_headers(entry.headers) do
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

  # Representation-aware content-type validation: a `{:complete_body, _}`
  # entry is validated as a generic MIME-shaped string (it is never an
  # encoder output format), everything else (including `nil`, the default
  # for entries that predate this field) keeps the original image-only check.
  @doc false
  @spec validate_content_type(String.t(), representation() | nil) :: :ok | {:error, term()}
  def validate_content_type(content_type, {:complete_body, _content_type}) do
    if valid_generic_content_type?(content_type) do
      :ok
    else
      {:error, {:invalid_content_type, content_type}}
    end
  end

  def validate_content_type(content_type, _representation),
    do: validate_content_type(content_type)

  defp valid_generic_content_type?(content_type) when is_binary(content_type),
    do: Regex.match?(@content_type_pattern, content_type)

  defp valid_generic_content_type?(_content_type), do: false

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
