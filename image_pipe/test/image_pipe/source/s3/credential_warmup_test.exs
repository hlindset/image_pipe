defmodule ImagePipe.Source.S3.CredentialWarmupTest do
  # async: false reduces suite contention so the supervised worker isn't starved
  # before it warms (issue #414). But the post-warm teardown — the gap between the
  # provider running and the worker's stop DOWN — is a separate wall-clock
  # wait that runner-wide scheduler steal can still push past the global 2s budget
  # even with async: false (issue #425). That DOWN is a guaranteed-arrival message
  # (the worker always returns {:stop, :normal, ...}); the passing path delivers it
  # near-instantly, so the explicit slack on it below is only a ceiling for a slow
  # runner, never a cost on success. If the worker stops before the monitor is
  # installed, Process.monitor/1 reports :noproc instead of the earlier :normal.
  use ExUnit.Case, async: false

  alias ImagePipe.Source.S3.Credentials
  alias ImagePipe.Source.S3.CredentialWarmup

  defmodule OnceProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def validate_options(_opts), do: :ok

    @impl true
    def fetch_credentials(opts) do
      send(Keyword.fetch!(opts, :test), {:warmed, Keyword.fetch!(opts, :id)})
      {:ok, [access_key_id: "A", secret_access_key: "S", token: "T"], :never}
    end
  end

  test "rejects invalid startup options before fetching credentials" do
    valid = [provider: OnceProvider, opts: [test: self(), id: :config]]

    for opts <- [
          Keyword.delete(valid, :provider),
          Keyword.put(valid, :unknown, true),
          Keyword.put(valid, :provider, "provider"),
          Keyword.put(valid, :opts, %{test: self()})
        ] do
      assert_raise RuntimeError, ~r/ArgumentError/, fn ->
        start_supervised!({CredentialWarmup, opts})
      end

      refute_received {:warmed, _}
    end
  end

  test "a provider that isn't a provider module raises before fetching credentials" do
    assert_raise RuntimeError, ~r/UndefinedFunctionError/, fn ->
      start_supervised!({CredentialWarmup, provider: nil, opts: []})
    end
  end

  test "delegates provider option validation before fetching credentials, keeping its reason" do
    assert_raise ArgumentError, ~r/invalid credential provider options: .*unknown/, fn ->
      CredentialWarmup.start_link(
        provider: ImagePipe.Source.S3.InstanceRole,
        opts: [unknown: true]
      )
    end
  end

  test "warms the cache entry at start so a later fetch does not re-fetch" do
    opts = [test: self(), id: :warm]
    pid = start_supervised!({CredentialWarmup, provider: OnceProvider, opts: opts})
    ref = Process.monitor(pid)
    assert_receive {:warmed, :warm}
    # the worker warms once then stops :normal; give the teardown DOWN generous
    # slack so a slow runner doesn't flake it (issue #425).
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    assert reason in [:normal, :noproc]

    # cache is warm: fetching does not invoke the provider again
    assert {:ok, _} = Credentials.fetch({:provider, OnceProvider, opts})
    refute_received {:warmed, :warm}
  end

  # The worker stops right after it starts the fetch, so its status is read
  # through the callback a crash report uses.
  test "status diagnostics leave out the provider options" do
    secret = "fake-base-secret"
    state = %{provider: OnceProvider, opts: [secret_access_key: secret]}
    refute inspect(CredentialWarmup.format_status(%{state: state})) =~ secret
  end

  test "warmups for different provider options start side by side without explicit ids" do
    for id <- [:first, :second],
        do:
          start_supervised!(
            {CredentialWarmup, provider: OnceProvider, opts: [test: self(), id: id]}
          )

    assert_receive {:warmed, :first}
    assert_receive {:warmed, :second}
  end
end
