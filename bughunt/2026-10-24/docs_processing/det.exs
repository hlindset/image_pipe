Code.require_file("/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/h.exs")
defmodule D.Base do
  defmacro __using__(o) do
    quote do
      @behaviour ImagePipe.Transform.Detector
      def supported_classes(_), do: ["a", "b", "face"]
      def available?(_), do: unquote(Keyword.get(o, :avail, true))
      def identity(_), do: {__MODULE__, 1}
    end
  end
end
defmodule D.Fail do use D.Base; def detect(_, _), do: {:error, :boom} end
defmodule D.Regions do use D.Base
  def detect(_, opts) do
    send(:tester, {:classes, opts[:classes]})
    all = [%{label: "a", score: 0.9, box: {0, 0, 10, 10}}, %{label: "b", score: 0.9, box: {200, 0, 20, 20}}, %{label: "b", score: 0.1, box: {290, 0, 50, 50}}]
    {:ok, Enum.filter(all, &(opts[:classes] == :all or &1.label in opts[:classes]))}
  end
end
defmodule D.Outside do use D.Base; def detect(_, _), do: {:ok, [%{label: "a", score: 1.0, box: {290, 0, 50, 50}}, %{label: "a", score: 1.0, box: {0,0,0,0}}]} end
defmodule D.NotReady do use D.Base; def detect(_, _), do: {:ok, [%{label: "b", score: 1.0, box: {200, 0, 20, 20}}]}; def ready?(_), do: :persistent_term.get(:rdy, false) end
defmodule D.Unavail do use D.Base, avail: false; def detect(_, _), do: {:error, {:detector, :unavailable}} end
Process.register(self(), :tester)
go = fn label, p, ex ->
  c = H.req(p, ex)
  left = if c.status == 200 and String.starts_with?(hd(Plug.Conn.get_resp_header(c, "content-type")), "image") do {:ok, i} = Image.from_binary(c.resp_body); {:ok, [r | _]} = Image.get_pixel(i, 0, 0); r end
  cls = receive do {:classes, cl} -> cl after 0 -> nil end
  IO.puts("R #{label} #{p} -> #{c.status} left=#{inspect left} cc=#{inspect Plug.Conn.get_resp_header(c, "cache-control")} etag=#{inspect Plug.Conn.get_resp_header(c, "etag")} classes=#{inspect cls} #{if c.status >= 400, do: c.resp_body}")
end
go.("fail", "/detect=a/crop=100,100/src/s300x200.png", detector: D.Fail)
go.("fail-req", "/detect=a/crop=100,100/src/s300x200.png", detector: D.Fail, detector_required: true)
go.("fail-req smartface", "/anchor=smart-face/crop=100,100/src/s300x200.png", detector: D.Fail, detector_required: true)
go.("fail smartface", "/anchor=smart-face/crop=100,100/src/s300x200.png", detector: D.Fail)
go.("regions a,b", "/detect=a,b/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("regions a:3,b", "/detect=a:3,b/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("regions a", "/detect=a/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("regions a:3", "/detect=a:3/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("regions all", "/detect=all/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("regions all:2,a:3", "/detect=all:2,a:3/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("smart only", "/anchor=smart/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("outside", "/detect=a/crop=100,100/src/s300x200.png", detector: D.Outside)
go.("notready", "/detect=a/crop=100,100/src/s300x200.png", detector: D.NotReady, detector_required: true)
go.("notready-notreq", "/detect=a/crop=100,100/src/s300x200.png", detector: D.NotReady)
go.("unavail", "/detect=a/crop=100,100/src/s300x200.png", detector: D.Unavail)
go.("unknown class", "/detect=zzz/crop=100,100/src/s300x200.png", detector: D.Regions)
go.("regions info", "/detect=a,b/crop=100,100/output=info/src/s300x200.png", detector: D.Regions)
go.("regions cover", "/detect=b/w=100/h=100/fit=cover/src/s300x200.png", detector: D.Regions)

go.("notready-notreq again", "/detect=a/crop=100,100/src/s300x200.png", detector: D.NotReady)
:persistent_term.put(:rdy, true)
go.("ready now", "/detect=a/crop=100,100/src/s300x200.png", detector: D.NotReady)
:persistent_term.put(:rdy, false)
for {l, ex} <- [{"nil req", [detector: nil, detector_required: true]}] do
  r = try do ImagePipe.Plug.init(Keyword.merge([allow_unsigned: true, sources: []], ex)); "OK" rescue e -> Exception.message(e) end
  IO.puts("R #{l} init: #{r}")
end
