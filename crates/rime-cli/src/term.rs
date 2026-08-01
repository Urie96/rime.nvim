//! Raw terminal mode + key event reading (xterm-style escape sequences →
//! X11 keysyms, the same ones the daemon/librime expect; see lua/rime/key.lua).
//!
//! 每个按键事件同时携带终端原始字节：rime 不消费的按键（含组合键、方向键、
//! 未识别的转义序列）会按原字节转发到 stdout，供 tmux pane 等消费方使用。

use crate::sys::{self, consts, PollFd, Termios};
use std::ffi::c_void;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

/// Set by SIGTERM/SIGINT handlers; the main loop polls it so the terminal is
/// restored by the `RawMode` guard on a clean exit.
pub static TERM_SHUTDOWN: AtomicBool = AtomicBool::new(false);

/// Saved terminal state so the `RawMode` guard can restore it on exit.
static ORIG_TERMIOS: Mutex<Option<Termios>> = Mutex::new(None);

extern "C" fn handle_signal(_sig: i32) {
    TERM_SHUTDOWN.store(true, Ordering::SeqCst);
}

pub fn install_signal_handlers() {
    unsafe {
        sys::c_signal(sys::SIGTERM, handle_signal);
        sys::c_signal(sys::SIGINT, handle_signal);
    }
}

/// X11 keysyms used by librime (values copied from lua/rime/key.lua).
pub const KEY_BACKSPACE: i32 = 0xff08;
pub const KEY_TAB: i32 = 0xff09;
pub const KEY_RETURN: i32 = 0xff0d;
pub const KEY_ESCAPE: i32 = 0xff1b;
pub const KEY_HOME: i32 = 0xff50;
pub const KEY_LEFT: i32 = 0xff51;
pub const KEY_UP: i32 = 0xff52;
pub const KEY_RIGHT: i32 = 0xff53;
pub const KEY_DOWN: i32 = 0xff54;
pub const KEY_PAGE_UP: i32 = 0xff55;
pub const KEY_PAGE_DOWN: i32 = 0xff56;
pub const KEY_END: i32 = 0xff57;
pub const KEY_DELETE: i32 = 0xffff;

/// librime modifier mask (kShiftMask=1, kControlMask=4, kMod1Mask=8).
pub const MOD_SHIFT: i32 = 1;
pub const MOD_CTRL: i32 = 4;
pub const MOD_ALT: i32 = 8;

/// STDIN_FILENO
const STDIN_FILENO: i32 = 0;

/// 解码后的按键。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Key {
    /// 可打印字符。ASCII 交给 rime；非 ASCII（如直接输入的中文）原样转发。
    Char(char),
    /// (keysym, modifier mask) 特殊键/组合键，交给 rime 判断是否消费。
    Code(i32, i32),
    /// 无法解码的序列（如 Ctrl+方向键 `\x1b[1;5A`）：不送 rime，原样转发。
    Raw(Vec<u8>),
    /// Ctrl-\：退出（不转发）。
    Quit,
}

/// 一个按键事件：解码结果 + 终端收到的原始字节。
#[derive(Debug, Clone)]
pub struct KeyEvent {
    pub key: Key,
    pub raw: Vec<u8>,
}

/// Raw-mode guard: restores the original termios on drop (clean exit only).
pub struct RawMode;

pub fn enable_raw() -> Result<RawMode, String> {
    let fd = STDIN_FILENO;
    let mut orig: Termios = unsafe { std::mem::zeroed() };
    if unsafe { sys::tcgetattr(fd, &mut orig) } != 0 {
        return Err(sys::last_os_error("tcgetattr"));
    }
    let mut raw = orig;
    raw.c_iflag &= !(consts::IGNBRK
        | consts::BRKINT
        | consts::PARMRK
        | consts::ISTRIP
        | consts::INLCR
        | consts::IGNCR
        | consts::ICRNL
        | consts::IXON);
    raw.c_oflag &= !consts::OPOST;
    raw.c_lflag &= !(consts::ECHO | consts::ECHONL | consts::ICANON | consts::ISIG | consts::IEXTEN);
    raw.c_cflag &= !(consts::CSIZE | consts::PARENB);
    raw.c_cflag |= consts::CS8;
    raw.c_cc[consts::VMIN] = 1;
    raw.c_cc[consts::VTIME] = 0;
    if unsafe { sys::tcsetattr(fd, consts::TCSANOW, &raw) } != 0 {
        return Err(sys::last_os_error("tcsetattr"));
    }
    *ORIG_TERMIOS.lock().unwrap() = Some(orig);
    Ok(RawMode)
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if let Ok(t) = ORIG_TERMIOS.lock() {
            if let Some(orig) = *t {
                unsafe { sys::tcsetattr(STDIN_FILENO, consts::TCSANOW, &orig) };
            }
        }
    }
}

fn fd_readable(fd: i32, timeout_ms: i32) -> bool {
    let mut pfd = PollFd {
        fd,
        events: consts::POLLIN,
        revents: 0,
    };
    (unsafe { sys::poll(&mut pfd, 1, timeout_ms) }) > 0
}

/// Read one byte directly from stdin (fd 0).
///
/// Unbuffered on purpose: `std::io::stdin()` fills an 8 KiB userspace buffer,
/// which would make `poll` on fd 0 miss bytes that are already in that buffer
/// (e.g. the rest of an escape sequence) — see the `\x1b[A` lookahead.
fn read_byte() -> io::Result<Option<u8>> {
    let mut b = [0u8; 1];
    let n = unsafe { sys::read(0, b.as_mut_ptr() as *mut c_void, 1) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    if n == 0 {
        Ok(None)
    } else {
        Ok(Some(b[0]))
    }
}

/// 带超时读一个字节（用于转义序列的后续字节探测）；超时返回 None。
fn read_byte_timeout(ms: i32) -> io::Result<Option<u8>> {
    if !fd_readable(STDIN_FILENO, ms) {
        return Ok(None);
    }
    read_byte()
}

/// Read one key event. Blocks (polling the shutdown flag) until a key is
/// available.
pub fn read_key() -> io::Result<Option<KeyEvent>> {
    loop {
        if TERM_SHUTDOWN.load(Ordering::SeqCst) {
            return Ok(Some(KeyEvent {
                key: Key::Quit,
                raw: Vec::new(),
            }));
        }
        if fd_readable(STDIN_FILENO, 100) {
            break;
        }
    }
    let first = match read_byte()? {
        Some(b) => b,
        None => return Ok(None),
    };
    let mut raw = vec![first];
    let key = match first {
        0x1c => Key::Quit,                  // Ctrl-\：退出（不转发）
        0x00 => Key::Code(0x20, MOD_CTRL),  // Ctrl-Space（中英切换，交给 rime）
        0x09 => Key::Code(KEY_TAB, 0),
        0x0d | 0x0a => Key::Code(KEY_RETURN, 0),
        0x08 | 0x7f => Key::Code(KEY_BACKSPACE, 0),
        0x1b => return read_escape().map(|e| e.map(|(key, raw)| KeyEvent { key, raw })),
        c if c < 0x20 => Key::Code((c as i32) + 0x40, MOD_CTRL), // Ctrl-字母等组合键
        c if c < 0x7f => Key::Char(c as char),
        c => match read_utf8_char(c, &mut raw)? {
            Some(ch) => Key::Char(ch),
            None => return read_key(), // invalid UTF-8: skip and read the next key
        },
    };
    Ok(Some(KeyEvent { key, raw }))
}

fn read_utf8_char(first: u8, raw: &mut Vec<u8>) -> io::Result<Option<char>> {
    let len = match first {
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => return Ok(None),
    };
    let mut buf = Vec::with_capacity(len);
    buf.push(first);
    for _ in 1..len {
        match read_byte()? {
            Some(b) => {
                raw.push(b);
                buf.push(b);
            }
            None => break,
        }
    }
    Ok(String::from_utf8(buf).ok().and_then(|s| s.chars().next()))
}

/// Parse an escape sequence after the leading `\x1b` byte.
/// 返回 (解码按键, 该事件消耗的全部原始字节)。
fn read_escape() -> io::Result<Option<(Key, Vec<u8>)>> {
    // Lone `\x1b` (nothing within 50ms) = Escape.
    let Some(b) = read_byte_timeout(50)? else {
        return Ok(Some((Key::Code(KEY_ESCAPE, 0), vec![0x1b])));
    };
    let mut raw = vec![0x1b, b];
    let key = match b {
        b'[' => {
            // CSI 序列：读到终结字节（0x40..=0x7e）为止，再整条匹配。
            loop {
                match read_byte_timeout(50)? {
                    Some(c) => {
                        raw.push(c);
                        if (0x40..=0x7e).contains(&c) {
                            break;
                        }
                    }
                    None => break, // 超时：序列不完整，按原样转发
                }
            }
            match raw.as_slice() {
                b"\x1b[A" => Key::Code(KEY_UP, 0),
                b"\x1b[B" => Key::Code(KEY_DOWN, 0),
                b"\x1b[C" => Key::Code(KEY_RIGHT, 0),
                b"\x1b[D" => Key::Code(KEY_LEFT, 0),
                b"\x1b[H" => Key::Code(KEY_HOME, 0),
                b"\x1b[F" => Key::Code(KEY_END, 0),
                b"\x1b[Z" => Key::Code(KEY_TAB, MOD_SHIFT),
                b"\x1b[1~" => Key::Code(KEY_HOME, 0),
                b"\x1b[3~" => Key::Code(KEY_DELETE, 0),
                b"\x1b[4~" => Key::Code(KEY_END, 0),
                b"\x1b[5~" => Key::Code(KEY_PAGE_UP, 0),
                b"\x1b[6~" => Key::Code(KEY_PAGE_DOWN, 0),
                b"\x1b[7~" => Key::Code(KEY_HOME, 0),
                b"\x1b[8~" => Key::Code(KEY_END, 0),
                // 未识别的 CSI（如 \x1b[1;5A = Ctrl+方向键）：原样转发
                _ => Key::Raw(raw.clone()),
            }
        }
        b'O' => {
            // SS3 序列（部分终端的 \x1bOA 等方向键）。
            loop {
                match read_byte_timeout(50)? {
                    Some(c) => {
                        raw.push(c);
                        if (0x40..=0x7e).contains(&c) {
                            break;
                        }
                    }
                    None => break,
                }
            }
            match raw.as_slice() {
                b"\x1bOA" => Key::Code(KEY_UP, 0),
                b"\x1bOB" => Key::Code(KEY_DOWN, 0),
                b"\x1bOC" => Key::Code(KEY_RIGHT, 0),
                b"\x1bOD" => Key::Code(KEY_LEFT, 0),
                b"\x1bOH" => Key::Code(KEY_HOME, 0),
                b"\x1bOF" => Key::Code(KEY_END, 0),
                _ => Key::Raw(raw.clone()),
            }
        }
        // Alt+字符（\x1bX）：交给 rime 判断，未消费则原样转发
        c if (0x20..=0x7f).contains(&c) => Key::Code(c as i32, MOD_ALT),
        // 其他前缀（如 \x1b\x7f = Alt+退格）：原样转发
        _ => Key::Raw(raw.clone()),
    };
    Ok(Some((key, raw)))
}
