defmodule ImagePipe.Source.S3.CredentialWarmupTest do
  # async: false on purpose: the supervised worker warms once in handle_continue
  # then stops :normal, so the only sync point is its own scheduling. Under a
  # loaded async suite the worker can be starved past the assert_receive window
  # (issue #414). There is nothing to :sys.get_state on — the process is already
  # gone by the time the continue returns — so removing suite contention is the
  # fix, not a longer timeout.
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
    # the worker warms once then stops :normal
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    # cache is warm: fetching does not invoke the provider again
    assert {:ok, _} = Credentials.fetch(scope, {:provider, OnceProvider, opts}, [])
    refute_received {:warmed, ^scope}
  end
end
