Code.require_file("/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/h.exs")
files = System.argv()
for f <- files, line <- (File.read!(f) |> String.split("\n") |> Enum.reduce({:out, []}, fn l, {st, acc} -> t = String.trim(l); cond do String.starts_with?(t, "```") and st != :out -> {:out, acc}; String.starts_with?(t, "```") -> {(if t in ["```text", "```sh", "```"], do: :keep, else: :skip), acc}; st == :keep -> {st, [l | acc]}; true -> {st, acc} end end) |> elem(1) |> Enum.reverse()) do
  line = String.trim(line)
  path = cond do
    String.starts_with?(line, "https://img.example.com/") -> String.replace_prefix(line, "https://img.example.com", "")
    String.starts_with?(line, "curl ") -> line |> String.split(" ") |> List.last() |> String.replace(~r{^https?://[^/]+}, "")
    String.starts_with?(line, "/") -> line
    true -> nil
  end
  if path && String.contains?(path, "src") do
    path = String.replace(path, "<signature>", "x")
    c = try do H.req(path) rescue e -> %{status: "RAISE #{inspect e}", resp_body: ""} end
    if true, do: IO.puts("URL #{Path.basename(f)} #{path} -> #{c.status} #{c.resp_body |> to_string() |> String.split("\n") |> Enum.reject(&(&1=="")) |> List.last()}")
  end
end
