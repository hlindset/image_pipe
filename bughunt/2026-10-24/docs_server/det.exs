d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
defmodule ZDet do
  @behaviour ImagePipe.Transform.Detector
  def mode, do: :persistent_term.get(:zdet_mode, :ok)
  @impl true
  def supported_classes(_), do: ["face", "cat"]
  @impl true
  def available?(_), do: :persistent_term.get(:zdet_avail, true)
  @impl true
  def ready?(_), do: :persistent_term.get(:zdet_ready, true)
  @impl true
  def identity(_), do: {__MODULE__, mode()}
  @impl true
  def detect(_img, _opts) do
    case mode() do
      :ok -> {:ok, [%{label: "face", score: 0.9, box: {0, 0, 100, 100}}]}
      :badbox -> {:ok, [%{label: "face", score: 0.9, box: {0, 0, 100}}]}
      :unavail -> {:error, {:detector, :unavailable}}
      :err -> {:error, :boom}
    end
  end
end
p = fn l, f -> r = try do f.() rescue e -> {:raised, e.__struct__, Exception.message(e) |> String.slice(0, 200)} end; IO.puts("#{l}: #{inspect(r, limit: 12, printable_limit: 300) |> String.slice(0, 400)}") end
src = [sources: [m: [adapter: ImagePipe.Source.File, match: :path, options: [root: d <> "/imgs", root_id: "m"]]]]
req = fn opts, path ->
  o = ImagePipe.Plug.init(src ++ [allow_unsigned: true, detector: ZDet] ++ opts)
  c = ImagePipe.Plug.call(Plug.Test.conn(:get, path), o)
  {c.status, Plug.Conn.get_resp_header(c, "cache-control"), Plug.Conn.get_resp_header(c, "etag") != [], if(c.status >= 400, do: c.resp_body)}
end
path = "/w=100/h=100/fit=cover/detect=face/src/photo.jpg"
for {m, r} <- [{:ok, false}, {:badbox, false}, {:badbox, true}, {:err, false}, {:err, true}, {:unavail, false}, {:unavail, true}] do
  :persistent_term.put(:zdet_mode, m)
  p.("mode=#{m} required=#{r}", fn -> req.([detector_required: r], path) end)
end
:persistent_term.put(:zdet_mode, :ok)
p.("unknown class", fn -> req.([], "/w=100/h=100/fit=cover/detect=dog/src/photo.jpg") end)
:persistent_term.put(:zdet_ready, false)
p.("not ready required", fn -> req.([detector_required: true], path) end)
p.("not ready not required", fn -> req.([detector_required: false], path) end)
:persistent_term.put(:zdet_ready, true); :persistent_term.put(:zdet_avail, false)
p.("unavailable config required", fn -> ImagePipe.config(detector: ZDet, detector_required: true) end)
p.("unavailable not required", fn -> req.([], path) end)
