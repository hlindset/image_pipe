defmodule ImagePipe.Security do
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  alias ImagePipe.Security.Signature
  alias ImagePipe.Security.Signature.Keys
  alias ImagePipe.Security.SourceEncryption

  defdelegate verify(signature, path, config), to: Signature

  def sign(path, config) do
    case Keyword.fetch!(config, :keys).values do
      [] -> nil
      [_ | _] -> Signature.sign(path, config)
    end
  end

  def encrypt_source(source, config, options),
    do: SourceEncryption.encrypt(source, Keyword.fetch!(config, :source_encryption), options)

  def decrypt_source(token, config),
    do: SourceEncryption.decrypt(token, Keyword.fetch!(config, :source_encryption))

  def extract!(options) do
    {keys, options} = Keyword.pop(options, :keys, [])
    keys = Keys.new!(keys)
    {source_keys, options} = Keyword.pop(options, :source_encryption_keys, [])
    {iv_mode, options} = Keyword.pop(options, :iv_mode, :deterministic)
    {encrypt_source, options} = Keyword.pop(options, :encrypt_source, false)

    case SourceEncryption.new(source_keys, iv_mode) do
      {:ok, encryption} ->
        validate!(keys, encryption)
        validate_generation!(encrypt_source, encryption)
        {[keys: keys, source_encryption: encryption, encrypt_source: encrypt_source], options}

      {:error, message} ->
        raise ArgumentError, "invalid ImagePipe.API source encryption: #{message}"
    end
  end

  defp validate_generation!(true, encryption) do
    if SourceEncryption.disabled?(encryption),
      do: raise(ArgumentError, "encrypt_source requires source encryption keys")
  end

  defp validate_generation!(false, _encryption), do: :ok

  defp validate_generation!(_value, _encryption),
    do: raise(ArgumentError, "encrypt_source must be a boolean")

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
