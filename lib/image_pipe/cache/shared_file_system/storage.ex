defmodule ImagePipe.Cache.SharedFileSystem.Storage do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.{Body, Partition}

  def adopt(plan, location, envelope, limits) do
    with :ok <- Partition.stage(plan),
         :ok <- adopt_body(plan, location, envelope.body, limits.body) do
      publish_metadata(plan, envelope.body, envelope.metadata, limits)
    end
  end

  defp adopt_body(%{kind: :sources}, _location, nil, _limit), do: :ok

  defp adopt_body(plan, location, expected, limit) do
    with {:ok, body} <-
           Body.adopt(Path.join(location.path, "body"), Path.join(plan.stage, "body"), limit) do
      verify_body(body, expected)
    end
  end

  # Run only in the isolated filesystem helper.
  def publish(plan, source, metadata, limits) do
    with :ok <- Partition.stage(plan),
         {:ok, body} <- prepare_body(plan, source, limits.body) do
      publish_metadata(plan, body, metadata, limits)
    end
  end

  defp publish_metadata(plan, body, metadata, limits) do
    envelope = %{
      kind: plan.kind,
      key: plan.key,
      generation: plan.generation,
      body: body,
      metadata: metadata
    }

    with {:ok, encoded} <- encode(envelope, limits.metadata),
         :ok <- File.write(Path.join(plan.stage, "meta"), encoded, [:exclusive]) do
      commit(plan, limits)
    end
  end

  defp prepare_body(%{kind: :sources}, nil, _limit), do: {:ok, nil}

  defp prepare_body(plan, source, limit),
    do: Body.copy(source, Path.join(plan.stage, "body"), limit)

  def commit(plan, limits) do
    location = Partition.location(plan.parent, plan.kind, plan.key, plan.generation)

    case File.rename(plan.stage, plan.destination) do
      :ok -> {:ok, location}
      {:error, reason} -> reconcile(location, limits, reason)
    end
  end

  defp reconcile(location, limits, rename_error) do
    with {:ok, envelope} <- metadata(location, limits.metadata),
         :ok <- verify_generation(location, envelope, limits) do
      {:ok, location}
    else
      {:error, :enoent} -> {:error, rename_error}
      error -> error
    end
  end

  defp verify_generation(_location, %{kind: :sources, body: nil}, _limits), do: :ok

  defp verify_generation(location, envelope, limits) do
    with {:ok, body} <- Body.digest(Path.join(location.path, "body"), limits.body) do
      verify_body(body, envelope.body)
    end
  end

  def acquire(location, directory, limits) do
    with {:ok, envelope} <- metadata(location, limits.metadata),
         :ok <- File.mkdir(directory),
         path = Path.join(directory, "body"),
         {:ok, body} <- Body.copy(Path.join(location.path, "body"), path, limits.body),
         :ok <- verify_body(body, envelope.body) do
      {:ok, %{path: path, metadata: envelope.metadata}}
    end
  end

  def metadata(location, limit) do
    case File.open(Path.join(location.path, "meta"), [:read, :binary], &IO.binread(&1, limit + 1)) do
      {:ok, encoded} when is_binary(encoded) and byte_size(encoded) <= limit ->
        with {:ok, envelope} <- decode(encoded, location) do
          {:ok, Map.put(envelope, :metadata_bytes, byte_size(encoded))}
        end

      {:ok, encoded} when is_binary(encoded) ->
        {:error, :metadata_too_large}

      {:ok, :eof} ->
        {:error, :corrupt}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def evict(partition, location) do
    retired = Path.join([partition.root, "trash", partition.id <> "-" <> location.generation])

    with :ok <- retire_generation(location.path, retired),
         :ok <- remove_file(Path.join(retired, "body")),
         :ok <- remove_file(Path.join(retired, "meta")) do
      case File.rmdir(retired) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  defp retire_generation(path, retired) do
    case File.rename(path, retired) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        case File.stat(retired) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          _uncertain -> {:error, reason}
        end
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp encode(envelope, limit) do
    encoded = :erlang.term_to_binary(envelope)

    case byte_size(encoded) <= limit do
      true -> {:ok, encoded}
      false -> {:error, :metadata_too_large}
    end
  end

  defp decode(<<131, 80, _rest::binary>>, _location), do: {:error, :corrupt}

  defp decode(encoded, location) do
    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {envelope, used} when used == byte_size(encoded) -> validate(envelope, location)
      _trailing_bytes -> {:error, :corrupt}
    end
  rescue
    ArgumentError ->
      {:error, :corrupt}
  end

  defp validate(
         %{key: key, kind: :sources, generation: generation, body: nil, metadata: encoded} =
           envelope,
         %{key: key, kind: :sources, generation: generation}
       )
       when is_binary(encoded), do: {:ok, envelope}

  defp validate(
         %{
           key: key,
           kind: kind,
           generation: generation,
           body: %{bytes: bytes, sha256: hash},
           metadata: encoded
         } = envelope,
         %{key: key, kind: kind, generation: generation}
       )
       when kind in [:outputs, :originals] and is_binary(encoded) and is_integer(bytes) and
              bytes >= 0 and
              is_binary(hash) and byte_size(hash) == 32,
       do: {:ok, envelope}

  defp validate(_envelope, _location), do: {:error, :corrupt}

  defp verify_body(body, body), do: :ok
  defp verify_body(_actual, _expected), do: {:error, :corrupt}
end
