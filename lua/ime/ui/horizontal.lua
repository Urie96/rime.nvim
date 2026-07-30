---Provide a horizontal UI.
---NOTE: `ui:draw()`'s output is `win:update()`'s input
---@module ime.ui.horizontal
local fn = require 'ime.fn'

local M = {
  --- config for IME UI
  UI = {
    left = '', -- symbol for left menu
    right = '', -- symbol for right menu
    left_sep = '', -- symbol for left separator
    right_sep = '', -- symbol for right separator
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

    -- Determine prefix
    local prefix
    if context.menu.highlighted_candidate_index + 1 == index then
      prefix = self.left_sep
    elseif context.menu.highlighted_candidate_index + 2 == index then
      prefix = self.right_sep
    else
      prefix = ' '
    end

    local segment = prefix .. body

    -- Index number position
    local idx_col = pos + #prefix
    table.insert(line_highlights, { idx_col, idx_col + #idx_str, 'RimeIndex' })

    -- Candidate text position (after index + space)
    local txt_col = idx_col + #idx_str + 1
    table.insert(line_highlights, { txt_col, txt_col + #candidate.text, 'RimeCandidate' })

    line = line .. segment
    pos = pos + #segment
  end

  -- Trailing separator
  if context.menu.num_candidates == context.menu.highlighted_candidate_index + 1 then
    line = line .. self.right_sep
  else
    line = line .. ' '
  end

  -- Left/right menu markers
  local col = 0
  local left = self.left
  if context.menu.page_no ~= 0 then
    -- Shift all highlights right by width of left marker
    local left_width = fn.strwidth(left)
    for _, hl in ipairs(line_highlights) do
      hl[1] = hl[1] + left_width
      hl[2] = hl[2] + left_width
    end
    line = left .. line
    local whitespace = ' '
    preedit = whitespace:rep(left_width) .. preedit
    col = col - left_width
  end
  if context.menu.is_last_page == false and context.menu.num_candidates > 0 then line = line .. self.right end

  local highlights = { [1] = line_highlights }

  return { preedit, line }, col, highlights
end

return M
