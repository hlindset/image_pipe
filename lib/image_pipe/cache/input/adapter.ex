defmodule ImagePipe.Cache.Input.Adapter do
  @moduledoc """
  Storage and coordination for source validation records and optional originals.

  Each adapter defines its coordination scope. Source selection and same-key
  validation have one owner within that scope. The local filesystem adapter uses
  its exclusively owned root; a shared filesystem adapter may use one writer
  incarnation, allowing nodes to retain independently valid source evidence.
  A snapshot describes the selection in that scope. A nil record is an
  invalidation marker, distinct from a miss. Revisions are opaque identities;
  callers never order them. An invalidation of an old revision must not remove
  a newer selection, and discovery must not undo a known local invalidation or
  evade validation already required by the selected record's policy.

  Acquire before reading source state for validation. Publication must verify
  ownership atomically when installing the selected revision, including after
  coordinator failure. A shared immutable disk write may finish after a timeout;
  its late completion must not install a selection under lost ownership or reset
  the origin-derived freshness of its evidence.
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
