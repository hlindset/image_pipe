mib = fn b -> Float.round(b / 1048576, 2) end
cs = Process.whereis(:code_server)
IO.inspect(Process.info(cs, [:memory, :total_heap_size, :heap_size, :stack_size, :message_queue_len]), label: "code_server before")
:erlang.garbage_collect(cs)
IO.inspect(Process.info(cs, [:memory, :total_heap_size, :heap_size]), label: "code_server after gc")
before = :erlang.memory(:processes)
Enum.each(Process.list(), &:erlang.garbage_collect/1)
IO.puts("processes before #{mib.(before)} after gc-all #{mib.(:erlang.memory(:processes))}")
