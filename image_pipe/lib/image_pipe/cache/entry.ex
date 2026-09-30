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
  @content_type_pattern ~r{\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+/[!#$%&'*+\-.^_`|~0-9A-Za-z]+( *;[^\x00-\x1F\x7F]*)?\z}

  defstruct @enforce_keys ++ [representation: nil, debug: nil, source_record: nil]

  @type header :: {String.t(), String.t()}
  # `representation` tags what an entry's `content_type`/`body` mean:
  # `{:image, format}` for the encoder-output path, or
  # `{:complete_body, content_type}` for a non-image complete
  # body (e.g. a BlurHash string). `nil` is treated identically to
  # `{:image, _}`: `validate/1` falls back to the
  # `Format`-based content-type check.
  @type representation :: {:image, atom()} | {:complete_body, String.t()}
  @type t :: %__MODULE__{
          body: binary() | ImagePipe.Cache.File.t(),
          content_type: String.t(),
          headers: [header()],
          created_at: DateTime.t(),
          representation: representation() | nil,
          debug: Info.t() | nil,
          source_record: ImagePipe.Source.Record.t() | nil
        }

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = entry) do
    with :ok <- validate_body(entry.body),
         :ok <- validate_source_record(entry.source_record),
         :ok <- validate_content_type(entry.content_type, entry.representation),
         {:ok, _headers} <- cacheable_headers(entry.headers) do
      :ok
    end
  end

  @doc false
  def validate_source_record(nil), do: :ok

  def validate_source_record(record) do
    case ImagePipe.Source.Record.valid?(record) do
      true -> :ok
      false -> {:error, :invalid_source_record}
    end
  end

  @doc false
  @spec validate_content_type(String.t()) :: :ok | {:error, term()}
  def validate_content_type(content_type) do
    if valid_generic_content_type?(content_type) do
      case Format.format_from_mime_type(content_type) do
        {:ok, _format} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_content_type, content_type}}
    end
  end

  @doc false
  @spec validate_content_type(String.t(), representation() | nil) :: :ok | {:error, term()}
  def validate_content_type(content_type, {:complete_body, content_type} = representation) do
    if valid_generic_content_type?(content_type) do
      :ok
    else
      {:error, {:invalid_representation, representation}}
    end
  end

  def validate_content_type(content_type, {:image, format} = representation) do
    case Format.mime_type(format) do
      {:ok, ^content_type} -> :ok
      _invalid_or_mismatched -> {:error, {:invalid_representation, representation}}
    end
  end

  def validate_content_type(content_type, nil) do
    case validate_content_type(content_type) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_content_type, reason}}
    end
  end

  def validate_content_type(_content_type, representation),
    do: {:error, {:invalid_representation, representation}}

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
  defp validate_body(%ImagePipe.Cache.File{}), do: :ok
  defp validate_body(body), do: {:error, {:invalid_body, body}}

  @doc "Closes a file-backed entry after use."
  def close(%__MODULE__{body: %ImagePipe.Cache.File{} = file}),
    do: ImagePipe.Cache.File.close(file)

  def close(%__MODULE__{}), do: :ok

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
