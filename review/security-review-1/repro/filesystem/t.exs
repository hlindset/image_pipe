Code.require_file("/tmp/claude-0/-home-user-image-pipe/149002c4-0ecf-54c3-b523-c73b50c63b54/scratchpad/fsrev/safe_path.ex")
root = Path.join(__DIR__, "root")
for p <- ["rel_out.jpg", "abs.jpg", "subl/ok.jpg", "sub/up.jpg", "fifo.jpg", "sub/../../x"] do
  r = ImagePipe.SafePath.relative(p, root)
  info = case r do {:ok, rel} -> :file.read_file_info(Path.join(root, rel), [:raw]) |> elem(1) |> then(&(if is_tuple(&1), do: elem(&1, 2), else: &1)); _ -> nil end
  IO.inspect({p, r, info})
end
IO.inspect(:file.read_file_info("a\0b", [:raw]), label: "nul")
