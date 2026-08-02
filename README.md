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
- 附带 Rust 编写的终端客户端 `rime-cli`（3 行界面：上屏文本 / preedit / 候选词），
  启动时自动连接 daemon，与 Neovim 共享同一引擎

## 依赖

| 依赖                    | 说明                                                       |
| ----------------------- | ---------------------------------------------------------- |
| Neovim ≥ 0.11           | 使用 `vim.pack.add`、`vim.system`、`vim.uv`                |
| librime                 | `rime-daemon` 的运行时依赖（daemon 在独立仓库编译安装）    |
| Rime 配置               | 至少一份 `default.yaml` + 方案文件（如 rime_ice）          |

## 安装

### 1. 安装 rime-daemon

`rime-daemon`（含 `rime-cli`）在独立仓库编译发布，**本插件不再负责编译**。
编译安装后把 `rime-daemon` 加入 `PATH`，或用 `RIME_DAEMON_BIN` 环境变量指定可执行文件路径。

### 2. 安装插件

以 lazy.nvim 为例：

```lua
{
  'Urie96/rime.nvim',
  config = function()
    local rime = require 'rime'
    rime.setup {
      shared_data_dir = '~/.config/rime',          -- 方案/词库源文件（只读，可省略）
      user_data_dir = '~/.local/share/rime.nvim',  -- 可写目录，部署产物 build/ 在此（可省略）
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
| `shared_data_dir` | 否   | Rime 方案与词库源文件目录；缺省时读 `RIME_SHARED_DATA_DIR` 环境变量，仍缺省则由 rime-daemon 按自身默认（`~/.config/rime`）查找 |
| `user_data_dir`   | 否   | 可写目录，librime 的用户数据与部署产物 `build/` 存放于此；缺省时读 `RIME_USER_DATA_DIR`，再缺省为 `~/.local/share/rime.nvim` |
| `log_dir`         | 否   | librime 日志目录；缺省时读 `RIME_LOG_DIR`，再缺省为 `~/.local/state/rime.nvim`              |

> 目录配置优先级：**`setup` 参数 > 环境变量 > 默认值**。三个目录均可省略——不传 `setup` 参数、
> 只在 shell 里设置 `RIME_SHARED_DATA_DIR` / `RIME_USER_DATA_DIR` / `RIME_LOG_DIR`（或
> `RIME_SOCKET`）也能工作，环境变量会透传给 daemon。

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

## 命令行客户端（rime-cli）

仓库还附带一个 Rust 编写的终端客户端 `rime-cli`：启动时自动连接常驻的
`rime-daemon`（未运行则自动拉起），在终端里直接使用同一套 Rime 引擎与用户词典
（与 Neovim 实例共享）。它是**键盘 → stdout 的转发器**：stdout 是数据通道，
可接入 tmux pane 等——rime 上屏的中文与未被 rime 消费的按键（字母、组合键、
方向键、Esc、未识别序列）都实时写入 stdout，让目标 pane 像被直接键入一样响应。
界面只有 2 行（画在 stderr）：

```
wo ai|　                                    ← 第 1 行：preedit（| 为光标）
1. 我  2. 握  3. 沃 …                          ← 第 2 行：候选词
```

```bash
# 运行（stdout 接入 pane，如：
#   tmux new-window 'rime-cli | 回放脚本'  # 或把 stdout 交给你的 pane 写入逻辑）
rime-cli > 数据流
```

转发规则：

| 事件 | stdout 输出 |
| ---- | ----------- |
| 候选/拼音上屏 | 上屏的中文文本 |
| rime 未消费的按键 | 终端原始字节（如 `\x1b[A` 方向键、`\x03` Ctrl-C、`\r` 回车、`\x7f` 退格） |
| 直接输入的非 ASCII 字符 | 原样字节 |
| `Esc` | 交给 rime（若方案把 Esc 绑定为进入 ascii 模式，之后按键会直接透传转发） |
| `Ctrl-\` | 退出（不转发） |

### 免中间层：`--exec` 直接执行命令

不想走 stdout 管道时，可用 `--exec` 指定一条命令模板（含 `{}` 占位符）：
每次需要转发字符时，把 `{}` 替换为本次转发的字符（作为单独参数），直接执行，
不再写 stdout。模板用 shlex（POSIX 分词）解析，支持 `'...'` / `"..."` 引号与
反斜杠转义，但**不经 sh**——不支持变量展开/通配符/重定向（需要时可显式 `sh -c`）：

```bash
rime-cli --exec 'tmux send-keys -t %1 -l {}'
# 等价于：每次转发时执行 tmux send-keys -t %1 -l 我
```

- 也可用环境变量 `RIME_EXEC` 指定（命令行参数优先）
- `-h` / `--help` 查看帮助
- 每次转发 spawn 一次命令（~ms 级），打字场景无感；占位符替换发生在分词之后，
  因此负载含空格/引号也始终是一个参数

常用按键（其余行为由 Rime 方案决定）：

| 按键                      | 作用                                        |
| ------------------------- | ------------------------------------------- |
| `1` ~ `9`、`0`            | 选择候选词上屏                              |
| `<Space>`                 | 有拼音串时上屏首选                          |
| `<Up>` / `<Down>`         | 上一页 / 下一页（映射为 PageUp / PageDown） |
| `<PageUp>` / `<PageDown>` | 翻页                                        |
| `Ctrl-Space`              | 中英切换（由方案 key_binder 处理）          |

环境变量（仅当 CLI 需要**自己拉起** daemon 时生效；已运行中的 daemon 直接复用）：

| 变量                     | 说明                                                          |
| ------------------------ | ------------------------------------------------------------- |
| `RIME_SOCKET`            | unix socket 路径，默认 `$XDG_RUNTIME_DIR` 或 `~/.local/state/rime.nvim` |
| `RIME_SHARED_DATA_DIR`   | 方案/词库目录，默认优先 `~/.config/rime`（存在时），否则 `~/.local/share/rime` |
| `RIME_USER_DATA_DIR`     | 可写数据目录，默认 `~/.local/share/rime.nvim`                |
| `RIME_LOG_DIR`           | 日志目录，默认 `~/.local/state/rime.nvim`                    |
| `RIME_DAEMON_BIN`        | rime-daemon 可执行文件路径（默认从 PATH 查找）              |

## 常见问题

- **开启输入法后打字仍是英文**：说明词库未部署，引擎回退到了内置空方案（schema 为 `.default`）。
  执行 `:RimeDeploy` 或检查 `user_data_dir` 是否可写、`build/` 是否生成。
  插件在 `setup` 时会自动部署一次，首次使用请耐心等待通知提示。
- **未找到 rime-daemon**：`rime-daemon` 需自行编译安装（见「安装」），
  可用 `RIME_DAEMON_BIN` 指定可执行文件路径，或将其加入 `PATH`。
- **daemon 相关调试**：日志在 `log_dir/rime-daemon.log`；`RIME_DAEMON_FOREGROUND=1` 可前台运行；
  socket 文件默认在 `$XDG_RUNTIME_DIR/rime-daemon.sock`（可用 `RIME_SOCKET` 覆盖）。
- **切换键在输入过程中失灵**：输入过程中插件会接管大部分特殊按键（数字选字、翻页等），
  但 `<C-x>` 已被明确排除在接管列表之外，始终保留给你绑定切换输入法。
