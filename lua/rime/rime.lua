---Consolidated rime for Neovim.
---@diagnostic disable: undefined-global
-- luacheck: ignore 112 113
local Win = require "rime.win".Win
local Keymap = require "rime.keymap".Keymap
local Key = require('rime.key').Key
local UI = require('rime.horizontal').UI
local Session = require('rime.session').Session

local M = {
    Rime = {
        win = Win(),
    }
}

---feed keys, wrap `vim.v.char`
---@param text string
function M.feed_keys(text)
    if vim.v.char ~= "" then
        vim.v.char = text
        return
    end
    -- input is <CR>
    if #text > 0 then
        vim.api.nvim_put({ text }, "b", false, true)
    end
end

---@param rime table?
---@return table rime
function M.Rime:new(rime)
    rime = rime or {}
    rime.keymap = rime.keymap or Keymap()
    rime.session = rime.session or Session()
    rime.ui = rime.ui or UI()
    if rime.trigger then rime:process(rime.trigger.code, rime.trigger.mask) end
    setmetatable(rime, { __index = self })
    return rime
end

setmetatable(M.Rime, {
    __call = M.Rime.new
})

---process keys through session and draw UI
---@param ... table
---@return string, string[], integer, table
function M.Rime:draw(...)
    for _, key in ipairs { ... } do
        local code = key.code
        if code == 65362 then        -- Up → Page_Up
            code = 65365
        elseif code == 65364 then    -- Down → Page_Down
            code = 65366
        end
        if not self.session:process_key(code, key.mask) then return tostring(key), {}, 0, {} end
    end
    local context = self.session:get_context()
    if context == nil or context.menu.num_candidates == 0 then return self.session:get_commit_text(), {}, 0, {} end
    local lines, col, highlights = self.ui:draw(context)
    return '', lines, col, highlights or {}
end

---wrap `self:draw()` with vim key name conversion
---@param ... string
---@return ...
function M.Rime:process(...)
    local keys = {}
    for _, name in ipairs { ... } do
        table.insert(keys, Key:from_vim(name))
    end
    return self:draw(unpack(keys))
end

---create autocmds.
---@param augroup_id integer?
function M.Rime:create_autocmds(augroup_id)
    augroup_id = augroup_id or vim.api.nvim_create_augroup("rime", {})

    vim.api.nvim_create_autocmd("InsertCharPre", {
        group = augroup_id,
        callback = self:callback()
    })

    vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
        group = augroup_id,
        callback = function()
            if not self:get_enabled() then
                return
            end
            self.session:clear_composition()
            self.win:update()
        end
    })
end

---get current schema ID, aka short name
---@return string
function M.Rime:get_current_schema()
    return self.session:get_current_schema()
end

---get current schema name
---@return string
function M.Rime:get_schema_name()
    return self.session:get_schema_name()
end

---execute rime for a single input character
---@param input string?
function M.Rime:exe(input)
    input = input or vim.v.char
    if not self.win:has_preedit() then
        for _, disable_key in ipairs(self.keymap.keys.disable) do
            if input == vim.keycode(disable_key) then
                self:disable()
                return
            end
        end
    end

    local text, lines, col, highlights = self:process(input)
    M.feed_keys(text)
    self.win:update(lines, col, highlights)
    self.keymap:set_special(self.win:has_preedit() and self.callback or nil, self)
end

---save the flag to use IM in insert mode for each buffer.
---@param is_enabled boolean
function M.Rime:set_enabled(is_enabled)
    self.keymap:set_nowait(is_enabled)
    vim.b.iminsert = is_enabled or nil
end

---check if rime is enabled for current buffer.
---@return boolean
function M.Rime:get_enabled()
    return vim.b.iminsert
end

---enable rime.
---@return boolean
function M.Rime:enable()
    if self:get_enabled() == false then
        self:set_enabled(true)
        return true
    end
    return false
end

---disable rime.
---@return boolean
function M.Rime:disable()
    if self:get_enabled() then
        self:set_enabled(false)
        return true
    end
    return false
end

---toggle rime on/off.
function M.Rime:toggle()
    self:set_enabled(not self:get_enabled())
end

---wrap `self:exe()` with enabled check
---@param ... any
function M.Rime:call(...)
    if not self:get_enabled() then
        return
    end
    self:exe(...)
end

---create a callback function for Neovim autocmds
---@param key any?
---@return function
function M.Rime:callback(key)
    return function()
        return self:call(key)
    end
end

---get an enable callback
---@return function
function M.Rime:enable_cb()
    return function()
        self:enable()
    end
end

---get a disable callback
---@return function
function M.Rime:disable_cb()
    return function()
        self:disable()
    end
end

---get a toggle callback
---@return function
function M.Rime:toggle_cb()
    return function()
        self:toggle()
    end
end

return M
