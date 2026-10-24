set pagination off
set $buf = (unsigned long*)malloc(64)
set $len = (unsigned long*)malloc(8)
set *$len = 8
set *$buf = 1
call (int)mallctl("epoch", 0, 0, $buf, 8)
set *$len = 8
call (int)mallctl("stats.allocated", $buf, $len, 0, 0)
printf "allocated %lu\n", *$buf
call (int)mallctl("stats.active", $buf, $len, 0, 0)
printf "active %lu\n", *$buf
call (int)mallctl("stats.metadata", $buf, $len, 0, 0)
printf "metadata %lu\n", *$buf
call (int)mallctl("stats.resident", $buf, $len, 0, 0)
printf "resident %lu\n", *$buf
call (int)mallctl("stats.mapped", $buf, $len, 0, 0)
printf "mapped %lu\n", *$buf
call (int)mallctl("stats.retained", $buf, $len, 0, 0)
printf "retained %lu\n", *$buf
set *$len = 4
call (int)mallctl("arenas.narenas", $buf, $len, 0, 0)
printf "narenas %u\n", *(unsigned int*)$buf
set *$len = 1
call (int)mallctl("background_thread", $buf, $len, 0, 0)
printf "background_thread %u\n", *(unsigned char*)$buf
detach
quit
