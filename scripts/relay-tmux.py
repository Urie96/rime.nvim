#!/usr/bin/env python3
"""relay-tmux.py — 把 stdin 字节流实时转发为 tmux send-keys。

用法：
    rime-cli | relay-tmux.py <target-pane>

target-pane 同 tmux 的 `-t` 参数，如 'mysession:mywin.0' 或 '.'（当前 pane）。

原理：
- 用 `os.read(0)` 直接读 fd（而非 sys.stdin.buffer.read）——后者是
  BufferedReader，会攒满内部缓冲（8192B）或 EOF 才返回，导致小数据
  等到 rime-cli 退出才流出。
- 逐块调用 `tmux send-keys -t <pane> -l` 透传。`-l` 不做键名/转义解析，
  字节原样进入 pane 输入流：中文 UTF-8 直接显示，`\\x1b[A` 是上箭头，
  `\\x03` 是 Ctrl-C，`\\r` 是回车，`\\x7f` 是退格——pane 里的程序按真实
  按键处理。
- 小块合并（满 512B 或 10ms 空闲）以减少 tmux 子进程调用，保持实时。

注意：流中的 NUL 字节（如 Ctrl-Space 透传）无法通过 exec 参数传递，会被丢弃。
"""
import os
import select
import subprocess
import sys

pane = sys.argv[1] if len(sys.argv) > 1 else '.'
FD = 0  # stdin
CHUNK = 512
IDLE = 0.01


def flush(buf: bytes) -> None:
    if not buf:
        return
    s = buf.decode('utf-8', 'surrogateescape')
    try:
        subprocess.run(['tmux', 'send-keys', '-t', pane, '-l', s], check=False)
    except OSError:
        pass  # pane 已关闭等


pending = b''
while True:
    r, _, _ = select.select([FD], [], [], IDLE)
    if FD in r:
        chunk = os.read(FD, 4096)  # read(2)：有多少返回多少，绝不攒
        if not chunk:  # EOF：rime-cli 退出
            flush(pending)
            break
        pending += chunk
        if len(pending) >= CHUNK:
            flush(pending)
            pending = b''
    else:
        flush(pending)
        pending = b''
