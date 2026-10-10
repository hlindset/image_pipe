defmodule ImagePipe.Test.ImgproxyReference.Container do
  @moduledoc """
  The pinned imgproxy image and the Docker helpers that `mix imgproxy.bake`
  and `mix imgproxy.bench` share, plus each reference case's request paths.
  """
  use Boundary, top_level?: true, check: [out: false]

  @version "v4.0.17"
  @image "darthsim/imgproxy:#{@version}@sha256:db0b4b9cd690c8b3590203dea300fb759a18c4ec2af7b37424f0bdef23ce317d"

  @spec version() :: String.t()
  def version, do: @version

  @spec image() :: String.t()
  def image, do: @image

  @spec native_path(map()) :: String.t()
  def native_path(%{kind: :png} = c), do: "/#{c.native}/format=png/src/#{c.source}"
  def native_path(%{kind: :lossy} = c), do: "/#{c.native}/src/#{c.source}"

  @spec imgproxy_path(map()) :: String.t()
  def imgproxy_path(%{kind: :png} = c),
    do: "/unsafe/#{c.imgproxy}/f:png/plain/local:///#{c.source}"

  def imgproxy_path(%{kind: :lossy} = c),
    do: "/unsafe/#{c.imgproxy}/plain/local:///#{c.source}"

  @spec docker!([String.t()]) :: String.t()
  def docker!(args) do
    case docker(args) do
      {out, 0} -> String.trim(out)
      {_out, status} -> Mix.raise("docker #{hd(args)} exited with #{status}")
    end
  end

  @spec docker([String.t()]) :: {String.t(), non_neg_integer()}
  def docker(args), do: System.cmd("docker", args)

  @doc "The host port Docker mapped to the container's port 8080."
  @spec mapped_port!(String.t()) :: String.t()
  def mapped_port!(container) do
    # `docker port` prints one `host:port` line per binding.
    docker!(["port", container, "8080/tcp"])
    |> String.split("\n", trim: true)
    |> List.first()
    |> String.split(":")
    |> List.last()
  end

  @doc "Polls `url` until it answers 200."
  @spec wait_until_ready!(String.t(), pos_integer()) :: :ok
  def wait_until_ready!(url, attempts \\ 60)
  def wait_until_ready!(url, 0), do: Mix.raise("#{url} did not become ready")

  def wait_until_ready!(url, attempts) do
    case Req.get(url, retry: false) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      _other ->
        Process.sleep(500)
        wait_until_ready!(url, attempts - 1)
    end
  end

  @doc """
  The ABI soname of the libvips in a running container's `dir`, such as
  `"42.20.2"`. imgproxy exposes no libvips version over HTTP.
  """
  @spec libvips(String.t(), String.t()) :: String.t()
  def libvips(container, dir) do
    ["exec", container, "sh", "-c", "basename $(ls #{dir}/libvips.so.42.* | head -1)"]
    |> docker!()
    |> String.replace_prefix("libvips.so.", "")
  end

  @spec imgproxy_libvips(String.t()) :: String.t()
  def imgproxy_libvips(container), do: libvips(container, "/opt/imgproxy/lib")
end
