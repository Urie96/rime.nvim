---Provide a horizontal UI.
---NOTE: `ui:draw()`'s output is `win:update()`'s input
---@module ime.ui.horizontal
local M = {
  --- config for IME UI
  UI = {
    cursor = '|', -- symbol for cursor
    indices = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' }, -- simple digits
  },
}

---@param ui table?
---@return table ui
function M.UI:new(ui)
  ui = ui or {}
  setmetatable(ui, {
    __index = self,
  })
  return ui
end

setmetatable(M.UI, {
  __call = M.UI.new,
})

---draw UI
---@param context table
---@return string[], integer, table
function M.UI:draw(context)
  local preedit = context.composition.preedit or ''
  preedit = preedit:sub(1, context.composition.cursor_pos)
    .. self.cursor
    .. preedit:sub(context.composition.cursor_pos + 1)

  local candidates = context.menu.candidates
  local indices = self.indices

  -- Build candidate line and track byte positions for highlighting
  local line = ''
  local line_highlights = {} -- { start_col, end_col, hl_group }
  local pos = 0 -- byte position tracker

  for index, candidate in ipairs(candidates) do
    local idx_str = indices[index]
    local body = idx_str .. ' ' .. candidate.text
    local segment = ' ' .. body

    -- Index number position (after the space prefix)
    local idx_col = pos + 1
    table.insert(line_highlights, { idx_col, idx_col + #idx_str, 'RimeIndex' })

    -- Candidate text position (after index + space)
    local txt_col = idx_col + #idx_str + 1
    table.insert(line_highlights, { txt_col, txt_col + #candidate.text, 'RimeCandidate' })

    line = line .. segment
    pos = pos + #segment
  end

  -- Trailing space
  line = line .. ' '

  local highlights = { [1] = line_highlights }

  return { preedit, line }, 0, highlights
end

return M
