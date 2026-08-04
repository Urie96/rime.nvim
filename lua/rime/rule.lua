---按上下文自动切换中/英文输入（自动模式）。
---
---标记机制（见 init.lua）：
---  - vim.b.iminsert  手动开关（C-space / enable / disable 写入）
---  - vim.b.rime_auto 自动标记，优先级高于 iminsert；规则能判断时写入，
---    无法判断时清除（回到手动），手动 C-space 切换时也会清除。
---  - vim.b.enable_auto_rime 控制自动切换：仅 true 启用；nil/false 时
---    清除自动标记并停止同步（完全手动，iminsert 决定一切）。
---
---决策规则（优先级从高到低）：
---  1. 光标前是中文 → 中文；是 a-zA-Z → 英文
---  2. 光标前是空格：空格前是中文（“中文+空格”）时，
---     光标后是中文 → 中文，否则 → 英文；空格前是 a-zA-Z（“字母+空格”）→ 英文
---  3. 光标前是数字/符号等无法判断的字符（含空格前是数字/符号）→ 向前扫描，
---     跳过数字/符号/空格，找第一个中文或字母决定
---  4. 扫描到行首仍未找到 → 尝试光标后：后中文 → 中文，后 a-zA-Z → 英文
---  5. 仍无法判断 → 清除自动标记（回到手动模式）
---
---组词期间拼音字母不写入 buffer、光标不动，因此不会打断正在进行的拼音输入。
---已知限制：在行尾用 a/A 追加时，光标列不会越过最后一个字符，可能少看一个字符。

local M = {}

---取以字节位置 pos（1 基）结尾的完整字符，返回 {start, char}；pos 越界返回 nil。
local function char_ending_at(line, pos)
  if pos < 1 then return nil end
  local b = line:byte(pos)
  if not b then return nil end
  local start = pos
  while start > 1 and line:byte(start) >= 0x80 and line:byte(start) <= 0xBF do
    start = start - 1
  end
  return { start = start, char = line:sub(start, pos) }
end

---取从字节位置 pos（1 基）开始的完整字符；pos 越界返回 nil。
local function char_starting_at(line, pos)
  local b = line:byte(pos)
  if not b then return nil end
  local len = 1
  if b >= 0xF0 then
    len = 4
  elseif b >= 0xE0 then
    len = 3
  elseif b >= 0xC0 then
    len = 2
  end
  return line:sub(pos, pos + len - 1)
end

---UTF-8 字符 → Unicode 码点
---@param c string
---@return integer
local function codepoint(c)
  local b1, b2, b3, b4 = c:byte(1, 4)
  if #c == 1 then return b1 end
  if #c == 2 then return (b1 - 0xC0) * 0x40 + (b2 - 0x80) end
  if #c == 3 then return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80) end
  return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
end

---是否中文字符（含扩展区、CJK 标点、全角形式）
---@param c string
---@return boolean
local function is_cjk(c)
  local u = codepoint(c)
  return (u >= 0x4E00 and u <= 0x9FFF) -- 基本区（常用汉字）
    or (u >= 0x3400 and u <= 0x4DBF) -- 扩展 A
    or (u >= 0xF900 and u <= 0xFAFF) -- 兼容表意
    or (u >= 0x20000 and u <= 0x2A6DF) -- 扩展 B
    or (u >= 0x3000 and u <= 0x303F) -- CJK 标点（。，、）
    or (u >= 0xFF00 and u <= 0xFFEF) -- 全角形式（，！（））
end

---是否 ASCII 字母
---@param c string
---@return boolean
local function is_ascii_letter(c)
  if #c ~= 1 then return false end
  local b = c:byte(1)
  return (b >= 0x61 and b <= 0x7A) or (b >= 0x41 and b <= 0x5A) -- a-z / A-Z
end

---是否空格（半角/不换行/全角）
---@param c string
---@return boolean
local function is_space(c)
  local u = codepoint(c)
  return u == 0x20 or u == 0xA0 or u == 0x3000
end

---从字节位置 pos（1 基）向前扫描，跳过空格/数字/符号等无法判断的字符，
---返回第一个可判断字符的状态；到行首未找到返回 nil。
---@param line string
---@param pos integer
---@return boolean|nil true=中文, false=英文
local function scan_backward(line, pos)
  local cur = pos
  while cur > 0 do
    local c = char_ending_at(line, cur)
    if not c then return nil end
    if is_cjk(c.char) then return true end
    if is_ascii_letter(c.char) then return false end
    cur = c.start - 1 -- 跳过空格/数字/符号等
  end
  return nil
end

---光标后字符判断：中文 → true，a-zA-Z → false，其他 → nil
---@param next string?
---@return boolean|nil
local function next_decision(next)
  if next and is_cjk(next) then return true end
  if next and is_ascii_letter(next) then return false end
  return nil
end

---向前扫描未找到时，回退到“看光标后”。
---@param line string
---@param from integer 扫描起始字节位置（1 基）
---@param next string?
---@return boolean|nil
local function decide_by_scan(line, from, next)
  local r = scan_backward(line, from)
  if r ~= nil then return r end
  return next_decision(next)
end

---根据上下文决定输入法状态。
---@return boolean|nil true=中文, false=英文, nil=无法判断（应清除自动标记）
local function decide()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0 基插入点字节偏移
  local prev = char_ending_at(line, col)
  local next = char_starting_at(line, col + 1)

  if not prev then
    -- 行首：看光标后
    return next_decision(next)
  end

  if is_cjk(prev.char) then return true end -- 前是中文 → 中文
  if is_ascii_letter(prev.char) then return false end -- 前是字母 → 英文

  if is_space(prev.char) then
    local prev2 = prev.start > 1 and char_ending_at(line, prev.start - 1)
    if prev2 then
      if is_cjk(prev2.char) then
        -- “中文+空格”：光标后是中文 → 中文，否则 → 英文
        return (next and is_cjk(next)) or false
      end
      if is_ascii_letter(prev2.char) then return false end -- “字母+空格” → 英文
    end
    -- 空格前是数字/符号/行首：向前扫描，未找到再看光标后
    local from = prev2 and prev2.start - 1 or 0
    return decide_by_scan(line, from, next)
  end

  -- 前是数字/符号等：向前扫描，未找到再看光标后
  return decide_by_scan(line, prev.start - 1, next)
end

---校正输入法状态：能判断则写入自动标记，不能则清除（回到手动）。
---仅当 vim.b.enable_auto_rime 为 true 时启用自动切换；否则清除标记并停止同步。
---@param rime table rime 模块（提供 set_auto）
local function sync_ime(rime)
  if vim.b.enable_auto_rime ~= true then
    vim.b.rime_auto = nil -- 未启用（nil/false）：清除自动标记，回到手动
    return
  end
  rime.set_auto(decide())
end

---注册按上下文自动切换的 autocmd。
---@param rime table rime 模块（提供 set_auto）
---@param group integer|string augroup id 或名称（与插件的 autocmd 共用）
function M.setup(rime, group)
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'CursorMovedI', 'TextChangedI' }, {
    group = group,
    callback = function() sync_ime(rime) end,
  })
end

return M
