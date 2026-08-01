#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_dir"

# ---------------------------------------------------------------------------
# Nix 可用 → 通过 derivation 构建 rime-daemon，产物软链到 bin/。
# 否则直接用 cargo 构建（需要 librime，可用 RIME_LIB_DIR 指定路径）。
# ---------------------------------------------------------------------------
if command -v nix-build &>/dev/null; then
  echo "use nix-build"
  rm -f result

  nix-build

  mkdir -p bin
  ln -sf ../result/bin/rime-daemon "$repo_dir/bin/rime-daemon"
else
  cargo build --release --workspace
fi

echo "rime-daemon built. 重启 Neovim 后生效。"
