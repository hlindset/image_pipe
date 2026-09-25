defmodule ImagePipe.Cache.SharedFileSystem.Metadata do
  @moduledoc false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Debug.Info
  alias ImagePipe.Source.{Origin, Record}

  def encode(metadata, limit) do
    case :erlang.external_size(metadata) <= limit do
      true -> {:ok, :erlang.term_to_binary(metadata)}
      false -> {:error, :metadata_too_large}
    end
  end

  def decode(_kind, <<131, 80, _rest::binary>>), do: {:error, :corrupt}

  def decode(kind, encoded) do
    # Load schema atoms before safe decoding. Host identity atoms belong to the
    # application VM that resolved the source, not the isolated filesystem VM.
    Enum.each([Record, Origin, Entry.Metadata, Info, DateTime], &Code.ensure_loaded!/1)

    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {metadata, used} when used == byte_size(encoded) -> validate(kind, metadata)
      _trailing -> {:error, :corrupt}
    end
  rescue
    _error in [ArgumentError, KeyError, FunctionClauseError, ArithmeticError] ->
      {:error, :corrupt}
  end

  defp validate(:sources, record) do
    case is_nil(record) or Record.valid?(record) do
      true -> {:ok, record}
      false -> {:error, :corrupt}
    end
  end

  defp validate(
         :outputs,
         %Entry.Metadata{created_at: %DateTime{calendar: Calendar.ISO}, cost_us: cost} = metadata
       )
       when is_integer(cost) and cost >= 0 do
    with :ok <- Entry.validate_content_type(metadata.content_type, metadata.representation),
         :ok <- Entry.validate_source_record(metadata.source_record),
         {:ok, headers} <- Entry.cacheable_headers(metadata.headers),
         true <- is_nil(metadata.debug) or is_struct(metadata.debug, Info),
         _timestamp <- DateTime.to_unix(metadata.created_at) do
      {:ok, %{metadata | headers: headers}}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp validate(:originals, %{source_record: record, cost_us: cost} = metadata)
       when is_integer(cost) and cost >= 0 do
    case Record.valid?(record) do
      true -> {:ok, metadata}
      false -> {:error, :corrupt}
    end
  end

  defp validate(_kind, _metadata), do: {:error, :corrupt}
end
