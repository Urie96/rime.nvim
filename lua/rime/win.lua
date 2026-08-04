local M = {
  win_id = -1,
  buf_id = vim.api.nvim_create_buf(false, true),
  ns_id = vim.api.nvim_create_namespace 'rime_win',
  lines = {},
  highlights = {},
  config = {},
}

local function ensure_highlight()
  vim.api.nvim_set_hl(0, 'RimeIndex', { fg = '#f9e2af' })
  vim.api.nvim_set_hl(0, 'RimeCandidate', {}) -- inherit Normal foreground
  vim.api.nvim_set_hl(0, 'RimePreedit', { fg = '#a6e3a1' })
end

---If the windows is valid
---@return boolean is_valid
function M.is_valid() return vim.api.nvim_win_is_valid(M.win_id) end

---If the windows has preedit
---@return boolean has_preedit
function M.has_preedit() return #M.lines > 1 end

---Open or close a window
function M._update()
  if #M.lines == 0 then
    if M.is_valid() then pcall(vim.api.nvim_win_close, M.win_id, false) end
    return
  end
  -- pcall 防御：若在 textlock（如 InsertCharPre）中意外触发，跳过本次更新
  -- 而非抛出 E565 中断整个输入链。
  if not pcall(vim.api.nvim_buf_set_lines, M.buf_id, 0, #M.lines, false, M.lines) then return end

  pcall(ensure_highlight)

  for line_idx, hl_list in pairs(M.highlights) do
    for _, hl in ipairs(hl_list) do
      local start_col, end_col, hl_group = hl[1], hl[2], hl[3]
      if start_col and end_col and hl_group then
        pcall(vim.api.nvim_buf_set_extmark, M.buf_id, M.ns_id, line_idx, start_col, {
          end_col = end_col,
          hl_group = hl_group,
          priority = 200,
        })
      end
    end
  end

  if M.is_valid() then
    pcall(vim.api.nvim_win_set_config, M.win_id, M.config)
  else
    local ok, win_id = pcall(vim.api.nvim_open_win, M.buf_id, false, M.config)
    if ok then M.win_id = win_id end
  end
end

---Wrap `self._update()`
---@param lines string[]?
---@param col integer?
---@param highlights table?
function M.update(lines, col, highlights)
  M.lines = lines or {}
  M.highlights = highlights or {}
  local width = 0
  for _, line in ipairs(M.lines) do
    width = math.max(vim.fn.strwidth(line), width)
  end
  M.config = {
    relative = 'cursor',
    height = #M.lines,
    style = 'minimal',
    width = width,
    row = 1,
    col = col or 0,
    zindex = 1000,
  }
  vim.schedule(function() M._update() end)
end

return M
