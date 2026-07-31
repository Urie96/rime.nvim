---wrap `rime.Session()`
local rimeshim = require 'rimeshim'
local Key = require('rime.key')
local M = {}

local _userdata

local log_level = { INFO = 0, WARNING = 1, ERROR = 2, FATAL = 3 }

---Initialize rime session (only once).
---@param opts { shared_data_dir: string, user_data_dir: string }
function M.init(opts)
  if _userdata then return end

  rimeshim.Traits(
    vim.fn.expand(opts.shared_data_dir),
    vim.fn.expand(opts.user_data_dir),
    vim.fn.expand '~/.local/state/rime.nvim',
    'Rime',
    'nvim-rime',
    '0.0.1',
    'rime.nvim-rime',
    log_level.FATAL
  )
  vim.fn.mkdir(vim.fn.expand '~/.local/state/rime.nvim', 'p')
  _userdata = rimeshim.Session()
end

function M.get_current_schema(...) return _userdata:get_current_schema(...) end

function M.select_schema(...) return _userdata:select_schema(...) end

---@return boolean
function M.process_key(...) return _userdata:process_key(...) end

function M.get_context(...) return _userdata:get_context(...) end

function M.get_commit(...) return _userdata:get_commit(...) end

---@return boolean
function M.commit_composition(...) return _userdata:commit_composition(...) end

function M.clear_composition(...) return _userdata:clear_composition(...) end

M.get_schema_list = rimeshim.get_schema_list

---@return string
function M.get_schema_name()
  local schemas = M.get_schema_list()
  local schema_id = M.get_current_schema()
  for _, schema in ipairs(schemas) do
    if schema.schema_id == schema_id then return schema.name end
  end
  return ''
end

---@return string
function M.get_commit_text()
  local text = ''
  if M.commit_composition() then
    local commit = M.get_commit()
    if commit then text = commit.text end
  end
  return text
end

---@param name string
---@return boolean
function M.parse_key(name)
  local key = Key.new { name = name }
  return M.process_key(key.code, key.mask)
end

---@param input string
---@return table
function M.get_full_context(input)
  for name in input:gmatch '(.)' do
    if M.parse_key(name) == false then break end
  end
  local result = M.get_context()
  local context = result
  while not context.menu.is_last_page do
    M.parse_key '='
    context = M.get_context()
    result.menu.num_candidates = result.menu.num_candidates + context.menu.num_candidates
    if result.menu.select_keys and context.menu.select_keys then
      for _, key in ipairs(context.menu.select_keys) do
        table.insert(result.menu.select_keys, key)
      end
    end
    if result.menu.candidates and context.menu.candidates then
      for _, candidate in ipairs(context.menu.candidates) do
        table.insert(result.menu.candidates, candidate)
      end
    end
  end
  M.clear_composition()
  result.menu.is_last_page = true
  return result
end

return M
