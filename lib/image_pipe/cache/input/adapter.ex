defmodule ImagePipe.Cache.Input.Adapter do
  @moduledoc """
  Storage and coordination for source validation records and optional originals.

  Source records have one authoritative owner. A snapshot with a nil record is
  an invalidation marker, distinct from a miss. Revisions are opaque identities;
  callers never order them. Adapters prevent an invalidation of an old revision
  from removing a newer one.

  Acquire before reading source state for validation. Publication must verify
  ownership atomically with its mutation, including after coordinator failure.
  Release ownership on completion; adapters also clean up when its owner dies.
  A nil path publishes only validation evidence, retaining matching originals
  when possible. Attempt to record evidence even if original admission fails.

  Opening original bytes returns a stable local path and an adapter-owned handle.
  The path remains usable until release, including during eviction. Adapters
  arrange cleanup on caller termination as well as explicit release. Callbacks
  receive only their own validated options. Runtime storage failures return errors
  and fail open at the facade; they must not extend source freshness.
  """
  alias ImagePipe.Cache.Input.Snapshot
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source.Record

  @callback validate_input_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  @callback lookup_source(Key.t(), keyword()) :: {:hit, Snapshot.t()} | :miss | {:error, term()}
  @callback acquire_source(Key.t(), keyword()) ::
              {:ok, term(), :acquired | :coalesced} | {:error, term()}
  @callback release_source(term(), keyword()) :: :ok | {:error, term()}
  @callback publish_source(
              Key.t(),
              term(),
              Record.t() | nil,
              Path.t() | nil,
              non_neg_integer(),
              keyword()
            ) ::
              {:ok, Snapshot.t()} | {:error, term()}
  @callback invalidate_source(Key.t(), term(), keyword()) :: :ok | {:error, term()}
  @callback open_input(Key.t(), Record.t(), keyword()) ::
              {:ok, Path.t(), term()} | :miss | {:error, term()}
  @callback release_input(term(), keyword()) :: :ok | {:error, term()}
end
