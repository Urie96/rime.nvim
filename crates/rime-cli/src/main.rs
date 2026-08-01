//! rime-cli: 终端版 Rime 输入法客户端——键盘 → tmux pane 转发器。
//!
//! 启动时自动连接常驻的 rime-daemon（未运行则自动拉起，参数见
//! `RIME_SOCKET` / `RIME_SHARED_DATA_DIR` / `RIME_USER_DATA_DIR` /
//! `RIME_LOG_DIR` / `RIME_DAEMON_BIN`）。
//!
//! 转发目标二选一：
//!   - stdout（默认）：上屏中文与未消费按键的原始字节写入 stdout；
//!   - `--exec <模板>`：每次转发直接执行解析后的命令（不经 sh，不再写 stdout），
//!     模板中 `{}` 被替换为本次转发的字符（作为单独参数）。
//!     例：`rime-cli --exec 'tmux send-keys -t %1 -l {}'`。
//!
//! 界面（2 行，画在 stderr）：
//!   第 1 行：preedit（拼音串，`|` 为光标）
//!   第 2 行：候选词（数字选字、翻页等）
//!
//! 退出：`Ctrl-\`（不转发）；外部 SIGTERM/SIGINT 亦可。

mod client;
mod sys;
mod term;
mod ui;

use std::ffi::OsString;
use std::io::Write;
use std::process::Command;

use client::Client;
use serde_json::json;

/// 转发目标。
enum Sink {
    /// 直接写入 stdout（默认）。
    Stdout,
    /// 每次转发直接执行解析后的命令（不经 sh）；`{}` 替换为本次负载。
    Exec(Vec<String>),
}

impl Sink {
    fn forward(&self, payload: &[u8]) {
        match self {
            Sink::Stdout => {
                let mut out = std::io::stdout().lock();
                let _ = out.write_all(payload);
                let _ = out.flush();
            }
            Sink::Exec(argv) => {
                let text = String::from_utf8_lossy(payload);
                let mut args: Vec<OsString> = Vec::with_capacity(argv.len());
                for a in argv {
                    args.push(OsString::from(a.replace("{}", &text)));
                }
                if let Some(prog) = args.first() {
                    if let Ok(mut child) = Command::new(prog).args(&args[1..]).spawn() {
                        let _ = child.wait(); // 等待保证转发顺序
                    }
                }
            }
        }
    }
}

/// 极简 shell 风格分词：按空白切分，支持 `'...'` 与 `"..."` 引号、反斜杠
/// 转义。不做变量展开/通配符/重定向——命令不经 sh，直接解析执行。
fn print_usage() {
    eprintln!("rime-cli — 键盘 → tmux pane 的 Rime 输入法转发器");
    eprintln!();
    eprintln!("用法: rime-cli [--exec <命令模板>]");
    eprintln!();
    eprintln!("  --exec <模板>   每次转发直接执行解析后的命令（不经 sh，不再写 stdout）；");
    eprintln!("                   模板中的 {{}} 被替换为本次转发的字符（作为一个参数）。");
    eprintln!("                   支持 '...' / \"...\" 引号与反斜杠转义；");
    eprintln!("                   不支持变量展开/通配符/重定向（需要时可在模板里显式 sh -c）。");
    eprintln!("                   例: rime-cli --exec 'tmux send-keys -t %1 -l {{}}'");
    eprintln!("                   也可用环境变量 RIME_EXEC 指定");
    eprintln!("  -h, --help      显示本帮助");
    eprintln!();
    eprintln!("退出: Ctrl-\\（不转发）；界面（preedit/候选）画在 stderr。");
}

/// 解析命令行参数，返回 --exec 模板（未指定时回退到 RIME_EXEC）。
/// 模板用 shlex（POSIX 分词）解析成 argv，支持引号/转义。
fn parse_args() -> Option<Vec<String>> {
    let mut args = std::env::args().skip(1);
    let mut exec = std::env::var("RIME_EXEC").ok();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--exec" | "-e" => exec = args.next(),
            "-h" | "--help" => {
                print_usage();
                std::process::exit(0);
            }
            other => {
                eprintln!("rime-cli: 未知参数: {other}");
                print_usage();
                std::process::exit(2);
            }
        }
    }
    match exec {
        Some(t) => match shlex::split(&t) {
            Some(argv) => {
                if !t.contains("{}") {
                    eprintln!("rime-cli: 警告: --exec 模板不含 {{}} 占位符，转发内容将无处安放");
                }
                Some(argv)
            }
            None => {
                eprintln!("rime-cli: --exec 模板引号不匹配: {t}");
                std::process::exit(2);
            }
        },
        None => None,
    }
}

fn main() {
    let exec_argv = parse_args();

    // 1. 启动时自动连接 daemon（未运行则拉起，最多重试约 10s）
    let sock = client::default_socket_path();
    let mut c = match client::connect_or_spawn(&sock) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("rime-cli: {e}");
            std::process::exit(1);
        }
    };

    // 2. 等待首次部署完成（新建会话前引擎必须就绪，否则会加载空 build/）
    wait_deployed(&mut c);

    // 3. 进入 raw 终端模式
    term::install_signal_handlers();
    let _raw = match term::enable_raw() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("rime-cli: {e}");
            std::process::exit(1);
        }
    };

    // 4. 主循环
    let mut st = ui::State::new();
    st.schema = fetch_schema_name(&mut c);

    let sink = match exec_argv {
        Some(argv) => Sink::Exec(argv),
        None => Sink::Stdout,
    };
    let mut tui = std::io::stderr(); // 界面（preedit/候选）画在 stderr

    loop {
        // 重绘 2 行界面
        let frame = ui::render(&st);
        if tui.write_all(frame.as_bytes()).is_err() || tui.flush().is_err() {
            break;
        }
        let ev = match term::read_key() {
            Ok(Some(e)) => e,
            Ok(None) => break, // EOF
            Err(e) => {
                let _ = tui.write_all(format!("\r\nrime-cli: 读取输入失败: {e}").as_bytes());
                break;
            }
        };
        if ev.key == term::Key::Quit {
            break;
        }
        handle_event(&mut c, &mut st, &sink, ev);
    }

    // 退出：恢复终端（Drop 还原 termios）
    let _ = tui.write_all(b"\x1b[0m\r\n");
    let _ = tui.flush();
}

/// 处理一个按键：rime 消费则同步界面并转发上屏文本；否则按原始字节转发。
fn handle_event(c: &mut Client, st: &mut ui::State, sink: &Sink, ev: term::KeyEvent) {
    match ev.key {
        term::Key::Char(ch) if ch.is_ascii() => {
            if c.process_key(ch as i32, 0).unwrap_or(false) {
                forward_commit(c, st, sink);
            } else {
                sink.forward(&ev.raw);
            }
        }
        term::Key::Char(_) => {
            // 非 ASCII（直接输入的中文/符号）：不经 rime，原样转发
            sink.forward(&ev.raw);
        }
        term::Key::Code(code, mask) => {
            // ↑/↓ 映射为 PageUp/PageDown 翻候选页（与 rime.nvim 插件一致）；
            // 无候选时 rime 不会消费，仍会按原始字节（方向键）转发。
            let (code, mask) = match (code, mask) {
                (term::KEY_UP, 0) => (term::KEY_PAGE_UP, 0),
                (term::KEY_DOWN, 0) => (term::KEY_PAGE_DOWN, 0),
                other => other,
            };
            let handled = c.process_key(code, mask).unwrap_or(false);
            if handled {
                forward_commit(c, st, sink);
            } else if code == term::KEY_RETURN && st.has_preedit() {
                // 有 preedit 且 rime 未消费回车：按输入法惯例本地上屏（转发其上屏文本）
                let _ = c.commit_composition();
                forward_commit(c, st, sink);
            } else {
                sink.forward(&ev.raw);
            }
        }
        term::Key::Raw(_) => {
            // 未识别的序列（如 Ctrl+方向键）：不经 rime，原样转发
            sink.forward(&ev.raw);
        }
        term::Key::Quit => {}
    }
}

/// 把本次新上屏的文本转发到目标（空文本不写）。
fn forward_commit(c: &mut Client, st: &mut ui::State, sink: &Sink) {
    let text = st.refresh(c);
    if !text.is_empty() {
        sink.forward(text.as_bytes());
    }
}

/// 等待 daemon 完成启动自动部署（仅首次使用较慢）。
fn wait_deployed(c: &mut Client) {
    match c.maintenance_mode() {
        Ok(false) => return,
        Ok(true) => {
            eprintln!("rime-cli: 首次使用，正在部署词库（仅需一次，请稍候）…");
            let start = std::time::Instant::now();
            loop {
                std::thread::sleep(std::time::Duration::from_millis(300));
                match c.maintenance_mode() {
                    Ok(false) => {
                        eprintln!("rime-cli: 部署完成");
                        return;
                    }
                    Ok(true) if start.elapsed().as_secs() > 600 => {
                        eprintln!("rime-cli: 部署超时，请检查 user_data_dir 是否可写");
                        return;
                    }
                    Err(e) => {
                        eprintln!("rime-cli: 查询部署状态失败: {e}");
                        return;
                    }
                    _ => {}
                }
            }
        }
        Err(e) => eprintln!("rime-cli: 查询部署状态失败: {e}"),
    }
}

/// 取当前方案显示名（查 schema_list 拿 name，失败则回退到 schema id）。
fn fetch_schema_name(c: &mut Client) -> Option<String> {
    let id = match c.request("session_current_schema", json!({})) {
        Ok(v) => v.as_str().unwrap_or("").to_string(),
        Err(_) => return None,
    };
    if id.is_empty() {
        return None;
    }
    let name = c
        .schema_list()
        .ok()
        .and_then(|list| list.into_iter().find(|(sid, _)| *sid == id).map(|(_, n)| n));
    Some(name.unwrap_or(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// shlex 分词后，`{}` 占位符应作为一个独立 token，替换时保持为单个参数。
    #[test]
    fn exec_argv_keeps_placeholder_as_token() {
        let argv = shlex::split("tmux send-keys -t %1 -l {}").unwrap();
        assert_eq!(argv, vec!["tmux", "send-keys", "-t", "%1", "-l", "{}"]);
    }

    #[test]
    fn shlex_handles_quotes() {
        assert_eq!(
            shlex::split("a 'b c' d \"e f\" g").unwrap(),
            vec!["a", "b c", "d", "e f", "g"]
        );
        assert!(shlex::split("unclosed '").is_none());
    }
}
