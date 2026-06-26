if Code.ensure_loaded?(Testcontainers) do
  defmodule ImagePipe.SourceTest.S3.IntegrationContainers do
    @moduledoc """
    Shared `testcontainers` plumbing for the opt-in `:aws_integration` smoke lane.

    Compiled only when the `testcontainers` dep is present (added by
    `AWS_INTEGRATION=1`/`IMGPROXY_DIFF=1`); a plain `mix test` skips this module
    entirely, so the integration lane cannot run on the default lane.

    How to run the whole lane (from the repo root):

        AWS_INTEGRATION=1 mise exec -- mix deps.get
        TESTCONTAINERS_RYUK_DISABLED=true \\
          mise exec -- mix test --include aws_integration

    Ryuk (testcontainers' reaper) fails locally, so it must be disabled; because
    it is disabled, each `start_*` helper stops its container explicitly via
    `on_exit`.
    """

    alias Testcontainers.Container

    # Pinned mock-server images. LocalStack 3.x ships the STS service; the EC2
    # metadata mock speaks IMDSv2 (token PUT) by default and serves IAM
    # security-credentials from its built-in defaults. Tags are confirmed on the
    # first inline run (a wrong tag fails the pull immediately and visibly).
    @localstack_image "localstack/localstack:3"
    @localstack_port 4566
    @metadata_mock_image "public.ecr.aws/aws-ec2/amazon-ec2-metadata-mock:v1.13.0"
    @metadata_mock_port 1338

    @doc """
    Idempotently start the testcontainers manager (its app deps + GenServer,
    which the app does not auto-start). Safe to call from every `setup_all`.
    """
    def ensure_started do
      {:ok, _} = Application.ensure_all_started(:testcontainers)

      case Testcontainers.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    @doc """
    Start LocalStack with the STS service and return its mapped base URL
    (e.g. `"http://localhost:32811"`). Registers `on_exit` cleanup.
    """
    def start_localstack_sts do
      base_url =
        @localstack_image
        |> Container.new()
        |> Container.with_exposed_port(@localstack_port)
        |> Container.with_environment("SERVICES", "sts")
        |> start_and_map(@localstack_port)

      wait_until_ready!(base_url <> "/_localstack/health")
      base_url
    end

    @doc """
    Start `amazon-ec2-metadata-mock` and return its mapped base URL. Registers
    `on_exit` cleanup. The returned URL has no trailing slash — `InstanceRole`
    appends `/latest/...` to its `:base_url`.
    """
    def start_ec2_metadata_mock do
      base_url =
        @metadata_mock_image
        |> Container.new()
        |> Container.with_exposed_port(@metadata_mock_port)
        |> start_and_map(@metadata_mock_port)

      # The mock does not force IMDSv2 locally, so an unauthenticated GET is fine
      # for readiness; the provider still drives the token-PUT path under test.
      wait_until_ready!(base_url <> "/latest/meta-data/")
      base_url
    end

    defp start_and_map(container, port) do
      {:ok, started} = Testcontainers.start_container(container)
      # Load-bearing ordering: register cleanup IMMEDIATELY after the container
      # starts and BEFORE the caller's `wait_until_ready!` poll. With Ryuk
      # disabled there is no reaper backstop, so if readiness times out and
      # raises, this already-registered `on_exit` is what stops the container.
      # Do NOT move the readiness poll before this registration.
      ExUnit.Callbacks.on_exit(fn -> Testcontainers.stop_container(started.container_id) end)
      mapped = Container.mapped_port(started, port)
      "http://localhost:#{mapped}"
    end

    # Bounded HTTP readiness poll. This `Process.sleep` is the accepted exception
    # to the no-sleep test rule: it waits on an external Docker container's HTTP
    # server, not an in-VM process (no monitor alternative exists).
    defp wait_until_ready!(url, attempts \\ 60)

    defp wait_until_ready!(url, 0) do
      raise "integration container at #{url} did not become ready"
    end

    defp wait_until_ready!(url, attempts) do
      case Req.get(url, retry: false) do
        {:ok, %Req.Response{status: status}} when status < 500 ->
          :ok

        _other ->
          Process.sleep(500)
          wait_until_ready!(url, attempts - 1)
      end
    end
  end
end
