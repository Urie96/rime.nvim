local Win = require 'rime.win'
local Keymap = require 'rime.keymap'
local Key = require 'rime.key'
local UI = require 'rime.ui'
local Session = require 'rime.session'
local M = {}

---Initialize rime with user config.
---@param opts { shared_data_dir?: string, user_data_dir?: string, log_dir?: string }
function M.setup(opts)
  Session.init(opts)

  vim.api.nvim_create_user_command('RimeDeploy', function(e)
    local t = vim.uv.hrtime()
    vim.notify 'Deploying Rime data…'
    local ok = Session.deploy(e.bang)
    if ok then
      vim.notify(string.format('Rime deploy finished in %.1fs', (vim.uv.hrtime() - t) / 1e9), 'info')
    else
      vim.notify('Rime deploy failed', 'error')
    end
  end, { bang = true, desc = 'Deploy rime data' })

  local augroup_id = vim.api.nvim_create_augroup('rime', {})
  -- 每次插入模式下输入一个字符前触发，把字符交给 Rime 处理
  vim.api.nvim_create_autocmd('InsertCharPre', {
    group = augroup_id,
    callback = function() return M.call() end,
  })

  vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
    group = augroup_id,
    callback = function()
      if not M.get_enabled() then return end
      Session.clear_composition()
      Win.update()
    end,
  })
end

---把 Rime 的产出（上屏文本）写回编辑器。
---在 InsertCharPre 中 vim.v.char 还没被消费，直接改写它即可替换本次输入；
---否则用 nvim_put 把文本插入光标处。
---@param text string
function M.feed_keys(text)
  if vim.v.char ~= '' then
    vim.v.char = text
    return
  end
  if #text > 0 then vim.api.nvim_put({ text }, 'b', false, true) end
end

---把按键逐个交给 Rime 引擎处理，返回 {上屏文本, 候选行, 光标列, 高亮}。
---@param key table
---@return string, string[], integer, table
function M.draw(key)
  local code = key.code
  -- 把 ↑/↓ 改写成 PageUp/PageDown，让上下键直接翻候选页。
  -- 按键码是 librime 沿用的 X11 keysym（见 key.lua 的 M.keys）：
  --   65362 (0xFF52) = XK_Up       65365 (0xFF55) = XK_PageUp
  --   65364 (0xFF54) = XK_Down     65366 (0xFF56) = XK_PageDown
  if code == 65362 then
    code = 65365
  elseif code == 65364 then
    code = 65366
  end
  -- 引擎返回 true 表示该键被 Rime 消费（如拼音串/候选上屏），继续处理后续键；
  -- 返回 false 表示未消费（如 Escape/回车），停止并把原始键交给编辑器
  if not Session.process_key(code, key.mask) then
    if (key.mask or 0) ~= 0 or key.code < (' '):byte() or key.code > ('~'):byte() then return '', {}, 0, {} end
    return string.char(key.code), {}, 0, {}
  end
  local context = Session.get_context()
  if context == nil or context.menu.num_candidates == 0 then return Session.get_commit_text(), {}, 0, {} end
  local lines, col, highlights = UI:draw(context)
  return '', lines, col, highlights or {}
end

---@return string?
function M.get_current_schema() return Session.get_current_schema() end

---@return string
function M.get_schema_name() return Session.get_schema_name() end

---@param input string?
function M.call(input)
  if not M.get_enabled() then return end

  input = input or vim.v.char
  -- 没有候选/拼音串时，按下禁用键直接关闭输入法
  if not Win.has_preedit() then
    for _, disable_key in ipairs(Keymap.keys.disable) do
      if input == vim.keycode(disable_key) then
        M.disable()
        return
      end
    end
  end

  local text, lines, col, highlights = M.draw(Key.from_vim(input))
  M.feed_keys(text)
  Win.update(lines, col, highlights)
  -- 有候选时把特殊键（数字选字、翻页等）映射到本函数，避免被编辑器拦截
  Keymap.set_special(Win.has_preedit() and M.callback or nil)
end

---启用状态直接存在 buffer 变量 iminsert 里，每个 buffer 独立记忆
---@param is_enabled boolean
function M.set_enabled(is_enabled) vim.b.iminsert = is_enabled end

---@return boolean
function M.get_enabled() return vim.b.iminsert or false end

function M.enable() M.set_enabled(true) end

function M.disable() M.set_enabled(false) end

function M.toggle() M.set_enabled(not M.get_enabled()) end

---@param key any?
---@return function
function M.callback(key)
  return function() return M.call(key) end
end

return M
