defmodule T do
  @dir "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
  def dir, do: @dir
  def key, do: String.duplicate("0123abcd", 8)
  def load(env) do
    try do
      {:ok, ImagePipeServer.Config.load!(env, Path.join(@dir, "none.toml"))}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
  def show(label, env, f \\ fn c -> c end) do
    IO.puts("== #{label}")
    case load(env) do
      {:ok, c} -> IO.inspect(f.(c), limit: :infinity, printable_limit: 400, label: "ok")
      {:error, m} -> IO.puts("ERROR: " <> m)
    end
  end
  def opts(c), do: c.image_pipe.options
end
