defmodule ImagePipe.Security do
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  alias ImagePipe.Security.Signature
  alias ImagePipe.Security.Signature.Keys
  alias ImagePipe.Security.SourceEncryption

  @options_schema NimbleOptions.new!(
                    keys: [
                      type: {:list, :string},
                      default: [],
                      type_doc: "list of hex-encoded `t:String.t/0`",
                      doc: """
                      Signing keys. The first key signs generated URLs. The server
                      accepts a signature from any key in the list, so keep an old
                      key while URLs signed with it are in use. Without keys, URLs
                      are unsigned and the server rejects signed ones.
                      """
                    ],
                    encrypt_source: [
                      type: :boolean,
                      default: false,
                      doc: """
                      Encrypts the source, and any watermark source, in generated URLs,
                      which then use `enc/<token>` instead of `src/<path>`. Requires
                      `:source_encryption_keys`. A server with encryption keys
                      decrypts `enc/` sources regardless of this option.
                      """
                    ],
                    source_encryption_keys: [
                      type: {:list, :string},
                      default: [],
                      type_doc: "list of 32-byte `t:binary/0`",
                      doc: """
                      Raw 32-byte keys that encrypt and decrypt sources. The first key
                      encrypts. The server decrypts with any key in the list. They must
                      differ from the signing keys, and setting them requires
                      `:keys`.
                      """
                    ],
                    iv_mode: [
                      type: {:in, [:deterministic, :random]},
                      default: :deterministic,
                      type_doc: "`:deterministic` or `:random`",
                      doc: """
                      How `ImagePipe.URL.url/3` picks the initialization vector for an
                      encrypted source. `:deterministic` derives it from the source with
                      a secret key, so one source always gives the same URL.
                      `:random` gives a new URL on every call.
                      """
                    ]
                  )

  @doc false
  def options_schema, do: @options_schema.schema

  defdelegate verify(signature, path, config), to: Signature

  def sign(path, config) do
    case Keyword.fetch!(config, :keys).values do
      [] -> nil
      [_ | _] -> Signature.sign(path, config)
    end
  end

  def encrypt_source(source, config, options),
    do: SourceEncryption.encrypt(source, Keyword.fetch!(config, :source_encryption), options)

  def encrypt_salted_source(source, config, salt),
    do: SourceEncryption.encrypt_salted(source, Keyword.fetch!(config, :source_encryption), salt)

  def decrypt_source(token, config),
    do: SourceEncryption.decrypt(token, Keyword.fetch!(config, :source_encryption))

  def extract!(options) do
    {security, options} = Keyword.split(options, Keyword.keys(@options_schema.schema))

    security =
      case NimbleOptions.validate(security, @options_schema) do
        {:ok, validated} -> validated
        {:error, error} -> raise ArgumentError, "invalid security option: #{error.key}"
      end

    keys = Keys.new!(Keyword.fetch!(security, :keys))
    source_keys = Keyword.fetch!(security, :source_encryption_keys)
    iv_mode = Keyword.fetch!(security, :iv_mode)
    encrypt_source = Keyword.fetch!(security, :encrypt_source)

    case SourceEncryption.new(source_keys, iv_mode) do
      {:ok, encryption} ->
        validate!(keys, encryption)
        validate_generation!(encrypt_source, encryption)
        {[keys: keys, source_encryption: encryption, encrypt_source: encrypt_source], options}

      {:error, message} ->
        raise ArgumentError, message
    end
  end

  defp validate_generation!(true, encryption) do
    if SourceEncryption.disabled?(encryption),
      do: raise(ArgumentError, "encrypt_source requires source encryption keys")
  end

  defp validate_generation!(false, _encryption), do: :ok

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
