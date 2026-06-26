defmodule ImagePipe.Source.S3.MetadataRequest do
  @moduledoc false
  # Shared bounded HTTP for the link-local AWS metadata endpoints used by the
  # InstanceRole (IMDS) and ContainerCredentials (ECS/EKS) providers. Uses the
  # non-bang `Req.request/1` flow with no redirects/retries and bounded timeouts;
  # any transport error becomes `{:error, :unreachable}`.

  @default_timeout_ms 2_000

  @spec request(keyword(), keyword()) :: {:ok, Req.Response.t()} | {:error, :unreachable}
  def request(opts, req_opts) do
    base =
      [
        retry: false,
        redirect: false,
        receive_timeout: timeout(opts, :receive_timeout),
        connect_options: [timeout: timeout(opts, :connect_timeout)]
      ]
      |> maybe_plug(opts)

    case Req.request(Keyword.merge(base, req_opts)) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, _exception} -> {:error, :unreachable}
    end
  end

  defp maybe_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp timeout(opts, key), do: Keyword.get(opts, key, @default_timeout_ms)
end
