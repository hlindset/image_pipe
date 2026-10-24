#!/bin/sh
# usage: rss.sh NODENAME -> RSS breakdown from /proc without touching the VM
P=$(pgrep -f "beam.*$1@" | head -1)
grep -E 'VmRSS|RssAnon|RssFile|RssShmem' /proc/$P/status | tr -s ' \n' ' '; echo
