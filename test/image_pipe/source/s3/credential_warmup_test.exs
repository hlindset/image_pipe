defmodule ImagePipe.Source.S3.CredentialWarmupTest do
  # async: false reduces suite contention so the supervised worker isn't starved
  # before it warms (issue #414). But the post-warm teardown — the gap between the
  # provider running and the worker's :normal stop DOWN — is a separate wall-clock
  # wait that runner-wide scheduler steal can still push past the global 2s budget
  # even with async: false (issue #425). That DOWN is a guaranteed-arrival message
  # (the worker always returns {:stop, :normal, ...}); the passing path delivers it
  # near-instantly, so the explicit slack on it below is only a ceiling for a slow
  # runner, never a cost on success.
  use ExUnit.Case, async: false

  alias ImagePipe.Source.S3.Credentials
  alias ImagePipe.Source.S3.CredentialWarmup

  defmodule OnceProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def fetch_credentials(scope, opts, _runtime) do
      send(Keyword.fetch!(opts, :test), {:warmed, scope})
      {:ok, [access_key_id: "A", secret_access_key: "S", token: "T"], :never}
    end
  end

  test "warms the cache entry at start so a later fetch does not re-fetch" do
    scope = "bucket-#{System.unique_integer([:positive])}"
    opts = [test: self()]

    pid =
      start_supervised!({CredentialWarmup, provider: OnceProvider, opts: opts, scope: scope})

    ref = Process.monitor(pid)
    assert_receive {:warmed, ^scope}
    # the worker warms once then stops :normal; give the teardown DOWN generous
    # slack so a slow runner doesn't flake it (issue #425).
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    # cache is warm: fetching does not invoke the provider again
    assert {:ok, _} = Credentials.fetch(scope, {:provider, OnceProvider, opts}, [])
    refute_received {:warmed, ^scope}
  end
end
