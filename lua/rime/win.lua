---Wrap `vim.api.nvim_open_win()`.
---NOTE: `ui:draw()`'s output is `win:update()`'s input
---@module rime.win
---@diagnostic disable: undefined-global
-- luacheck: ignore 112 113
-- ensure rime highlight groups exist
local function ensure_highlights()
  pcall(vim.api.nvim_set_hl, 0, 'RimeIndex', { fg = '#909090' })
  pcall(vim.api.nvim_set_hl, 0, 'RimeCandidate', {}) -- inherit Normal foreground
end

local M = {
    Win = {
        win_id = -1,
        lines = {},
        highlights = {},
        config = {},
    }
}

---@param win table?
---@return table Win
function M.Win:new(win)
    win = win or {}
    win.buf_id = vim.api.nvim_create_buf(false, true)
    win.ns_id = vim.api.nvim_create_namespace('rime_win')
    win.highlights = {}
    setmetatable(win, {
        __index = self
    })
    return win
end

setmetatable(M.Win, {
    __call = M.Win.new
})

---If the windows is valid
---@return boolean is_valid
function M.Win:is_valid()
    return vim.api.nvim_win_is_valid(self.win_id)
end

---If the windows has preedit
---@return boolean has_preedit
function M.Win:has_preedit()
    return #self.lines > 1
end

---Open or close a window
function M.Win:_update()
    if #self.lines == 0 then
        if self:is_valid() then
            vim.api.nvim_win_close(self.win_id, false)
        end
        return
    end
    vim.api.nvim_buf_set_lines(self.buf_id, 0, #self.lines, false, self.lines)

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(self.buf_id, self.ns_id, 0, -1)
    ensure_highlights()

    for line_idx, hl_list in pairs(self.highlights) do
        for _, hl in ipairs(hl_list) do
            local start_col, end_col, hl_group = hl[1], hl[2], hl[3]
            if start_col and end_col and hl_group then
                pcall(vim.api.nvim_buf_set_extmark, self.buf_id, self.ns_id, line_idx, start_col, {
                    end_col = end_col,
                    hl_group = hl_group,
                    priority = 200,
                })
            end
        end
    end

    if self:is_valid() then
        vim.api.nvim_win_set_config(self.win_id, self.config)
    else
        self.win_id = vim.api.nvim_open_win(self.buf_id, false, self.config)
    end
end

---Wrap `self._update()`
---@param lines string[]?
---@param col integer?
---@param highlights table?
function M.Win:update(lines, col, highlights)
    self.lines = lines or {}
    self.highlights = highlights or {}
    local width = 0
    for _, line in ipairs(self.lines) do
        width = math.max(vim.fn.strwidth(line), width)
    end
    self.config = {
        relative = "cursor",
        height = #self.lines,
        style = "minimal",
        width = width,
        row = 1,
        col = col or 0,
    }
    vim.schedule(
        function()
            self:_update()
        end
    )
end

return M
