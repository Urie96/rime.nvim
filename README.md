# rime.nvim

在 Neovim 中直接使用 [Rime](https://github.com/rime/librime) 输入法引擎的中文输入插件，无需系统输入法。
librime 运行在独立的 Rust 守护进程（`rime-daemon`）中，Neovim 通过 unix socket 与之通信：
**每个 Neovim 实例一个连接 = 一个 librime session**，多个实例共享同一引擎与用户词典。

## 特性

- librime 常驻独立进程（`rime-daemon`，Rust 实现），不依赖 fcitx/ibus 等系统输入法框架
- 多个 Neovim 实例共享同一个引擎与用户词典（LevelDB userdb 单进程打开，无锁冲突）
- 输入过程中浮窗显示 preedit（拼音串）与候选词
- 首次使用自动部署词库（编译 `.table.bin` / `.prism.bin`），之后增量更新
- 每个 buffer 独立记忆输入法开关状态（基于 `iminsert`）
- 支持候选高亮、翻页、`<Space>` 上屏 / 关闭
- daemon 懒启动：第一个实例自动拉起，最后一个实例退出后自动关闭

## 依赖

| 依赖                    | 说明                                                       |
| ----------------------- | ---------------------------------------------------------- |
| Neovim ≥ 0.11           | 使用 `vim.pack.add`、`vim.system`、`vim.uv`                |
| Rust toolchain          | 编译 `rime-daemon`（cargo + rustc）                        |
| librime（含开发头文件） | `rime-daemon` 链接 librime，可用 `RIME_LIB_DIR` 指定路径   |
| Rime 配置               | 至少一份 `default.yaml` + 方案文件（如 rime_ice）          |

## 安装

### 1. 编译 rime-daemon

插件根目录执行（有 `nix-build` 时走 Nix derivation，否则用 cargo）：

```bash
./build.sh
# 或手动：
# RIME_LIB_DIR=/opt/homebrew/opt/librime/lib cargo build --release --workspace   # macOS Homebrew 示例
```

产物为 `target/release/rime-daemon`（Nix 构建时会软链到 `bin/rime-daemon`）。
编译完成后需要重启 Neovim。

### 2. 安装插件

以 lazy.nvim 为例：

```lua
{
  'Urie96/rime.nvim',
  build = './build.sh', -- 自动编译 rime-daemon（Rust）
  config = function()
    local rime = require 'rime'
    rime.setup {
      shared_data_dir = '~/.config/rime',          -- 方案/词库源文件（只读）
      user_data_dir = '~/.local/share/rime.nvim',  -- 可写目录，部署产物 build/ 在此
    }
    -- 切换输入法的按键（按需自定义）
    vim.keymap.set('i', '<C-x>', function() rime.toggle() end, { desc = 'Toggle Rime' })
  end,
}
```

手动安装（`packadd`）：

```lua
-- 把仓库放到 ~/.local/share/nvim/site/pack/core/opt/rime.nvim 后：
vim.pack.add { 'https://github.com/Urie96/rime.nvim' }
local rime = require 'rime'
rime.setup { ... }
```

> **注意**：`user_data_dir` 必须可写，
> 不要与 dotfiles 仓库等只读/版本管理目录共用。

## 配置

### `setup(opts)`

| 参数              | 必填 | 说明                                                                                      |
| ----------------- | ---- | ----------------------------------------------------------------------------------------- |
| `shared_data_dir` | 是   | Rime 方案与词库源文件目录（如 `~/.config/rime`）                                          |
| `user_data_dir`   | 否   | 可写目录，librime 的用户数据与部署产物 `build/` 存放于此，默认 `~/.local/share/rime.nvim` |
| `log_dir`         | 否   | librime 日志目录，默认 `~/.local/state/rime.nvim`                                          |

### 可用 API

| 函数                                       | 说明                              |
| ------------------------------------------ | --------------------------------- |
| `rime.toggle()` / `enable()` / `disable()` | 切换 / 开启 / 关闭输入法          |
| `rime.get_enabled()`                       | 当前是否开启                      |
| `rime.get_current_schema()`                | 当前方案 id                       |
| `rime.get_schema_name()`                   | 当前方案名称                      |
| `rime.call(input)`                         | 把一个按键/字符交给 Rime 引擎处理 |

## 使用方法

1. 插入模式下按切换键（如 `<C-x>`）开启输入法
2. 输入拼音，浮窗显示 preedit 与候选词
3. 常用操作：

| 按键                      | 作用                                            |
| ------------------------- | ----------------------------------------------- |
| `1` ~ `9`、`0`            | 选择候选词上屏                                  |
| `<Space>`                 | 有拼音串时上屏首选；无拼音串时关闭输入法        |
| `<Up>` / `<Down>`         | 上一页 / 下一页（内部映射为 PageUp / PageDown） |
| `<PageUp>` / `<PageDown>` | 翻页                                            |
| `<Esc>`                   | 退出插入模式（自动清除未上屏的拼音）            |

> 其他按键行为（如 `-`/`=` 翻页、`Control+space` 切换中英文）由 Rime 方案自身的
> `key_binder` 配置决定。

## 命令

### `:RimeDeploy`

运行 librime 维护（部署）：检测方案/词库变更后增量重建编译产物到 `user_data_dir/build/`。
修改了 `shared_data_dir` 里的 Rime 配置后执行此命令即可生效，无需重启。

### `:RimeDeploy!`

强制全量重建词库与方案（忽略增量检测）。

### `:RimeBuildDaemon`

重新编译 `rime-daemon`（在插件根目录执行 `cargo build --release --workspace`）。
更新了插件版本或更换 librime 后使用。

## 常见问题

- **开启输入法后打字仍是英文**：说明词库未部署，引擎回退到了内置空方案（schema 为 `.default`）。
  执行 `:RimeDeploy` 或检查 `user_data_dir` 是否可写、`build/` 是否生成。
  插件在 `setup` 时会自动部署一次，首次使用请耐心等待通知提示。
- **更新插件后需要重新编译**：`target/release/rime-daemon` 是编译产物，更新插件版本后执行
  `:RimeBuildDaemon`（或 lazy.nvim 的 `build` 钩子）重新编译。
- **daemon 相关调试**：日志在 `log_dir/rime-daemon.log`；`RIME_DAEMON_FOREGROUND=1` 可前台运行；
  socket 文件默认在 `$XDG_RUNTIME_DIR/rime-daemon.sock`（可用 `RIME_SOCKET` 覆盖）。
- **切换键在输入过程中失灵**：输入过程中插件会接管大部分特殊按键（数字选字、翻页等），
  但 `<C-x>` 已被明确排除在接管列表之外，始终保留给你绑定切换输入法。
