#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

# ---------------------------------------------------------------------------
# Nix 可用 → 通过 derivation 构建，确保 lua/rime.so 携带对 librime 的
# store 引用，避免被 GC 回收。
# ---------------------------------------------------------------------------
if command -v nix-build &>/dev/null; then
  echo "use nix-build"
  rm -f result

  nix-build

  ln -sf ../result/lua/rime.so "$repo_dir/lua/rime.so"
else
  exec make
fi
