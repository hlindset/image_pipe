defmodule ImagePipe.SourceTest.CredentialProvider do
  @moduledoc false

  @behaviour ImagePipe.Source.S3.CredentialProvider

  @impl true
  def fetch_credentials(scope, provider_opts, runtime_opts) do
    # Credentials run inside the RefreshCache's task, so the test process is not
    # reachable via `$callers`. Tests that assert the provider was called pass
    # `report_to: self()`; it is stripped from the reported opts so assertions
    # see only the meaningful provider options.
    {target, reported_opts} = Keyword.pop(provider_opts, :report_to)
    send(target || message_target(), {:fetch_credentials, scope, reported_opts, runtime_opts})

    {:ok,
     [
       access_key_id: "AKIA_TEST",
       secret_access_key: "SECRET_TEST",
       token: "TOKEN_TEST"
     ], :never}
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
