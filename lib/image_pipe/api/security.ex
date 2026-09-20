defmodule ImagePipe.API.Security do
  @moduledoc false

  alias ImagePipe.API.Signature.Keys
  alias ImagePipe.API.SourceEncryption

  def extract!(options) do
    {keys, options} = Keyword.pop(options, :keys, [])
    keys = Keys.new!(keys)
    {source_keys, options} = Keyword.pop(options, :source_encryption_keys, [])
    {iv_mode, options} = Keyword.pop(options, :iv_mode, :deterministic)

    case SourceEncryption.new(source_keys, iv_mode) do
      {:ok, encryption} ->
        validate!(keys, encryption)
        {[keys: keys, source_encryption: encryption], options}

      {:error, message} ->
        raise ArgumentError, "invalid ImagePipe.API source encryption: #{message}"
    end
  end

  defp validate!(keys, encryption) do
    cond do
      SourceEncryption.disabled?(encryption) ->
        :ok

      keys.values == [] ->
        raise ArgumentError, "source encryption requires signing keys"

      Enum.any?(keys.values, &SourceEncryption.key?(encryption, &1)) ->
        raise ArgumentError, "signing and source encryption keys must be independent"

      true ->
        :ok
    end
  end
end
