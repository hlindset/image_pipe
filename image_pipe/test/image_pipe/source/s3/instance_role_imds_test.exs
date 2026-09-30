if Code.ensure_loaded?(Testcontainers) do
  defmodule ImagePipe.Source.S3.InstanceRoleImdsTest do
    @moduledoc """
    Opt-in protocol-fidelity smoke test for `InstanceRole` against a real
    `amazon-ec2-metadata-mock`, provisioned via testcontainers. NOT a correctness
    gate (the IMDSv2 token/role/creds parse path is covered hermetically by the
    Req `:plug` unit tests in `instance_role_test.exs`); this confirms an
    independent IMDS implementation accepts our token-PUT-then-GET sequence and
    returns parseable credentials.

    How to run (from the repo root):

        AWS_INTEGRATION=1 mise exec -- mix deps.get
        TESTCONTAINERS_RYUK_DISABLED=true \\
          mise exec -- mix test --include aws_integration

    Compiled only when `testcontainers` is present and tagged `:aws_integration`
    (excluded from the default lane), so a normal `mix test` never touches it.
    """
    use ExUnit.Case, async: false

    @moduletag :aws_integration

    alias ImagePipe.Source.S3.InstanceRole
    alias ImagePipe.SourceTest.S3.IntegrationContainers

    setup_all do
      IntegrationContainers.ensure_started()
      base_url = IntegrationContainers.start_ec2_metadata_mock()
      %{base_url: base_url}
    end

    test "fetches temporary credentials via IMDSv2 from a real metadata mock", %{
      base_url: base_url
    } do
      # InstanceRole always does the IMDSv2 token PUT first, then the role-list
      # GET, then the creds GET — so a successful result implies the mock honored
      # the token PUT. The role name is read from the mock's listing endpoint
      # (not hardcoded), so this tolerates whatever default profile it serves.
      assert {:ok, creds, %DateTime{}} =
               InstanceRole.fetch_credentials("any-bucket", [base_url: base_url], [])

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:secret_access_key])
      assert is_binary(creds[:token])
    end
  end
end
