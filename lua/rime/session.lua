---wrap `rime.Session()`
local rimeshim = require 'rimeshim'
local Key = require('rime.key')
local M = {}

local _userdata

-- 保存用户 setup 时传入的配置
local config = {}

local log_level = { INFO = 0, WARNING = 1, ERROR = 2, FATAL = 3 }

---Initialize rime session (only once).
---@param opts { shared_data_dir: string, user_data_dir?: string, log_dir?: string }
function M.init(opts)
  if _userdata then return end

  -- 先创建目录再初始化 librime：否则 glog 无法写日志、部署也无法写 build/，会静默失败
  local log_dir = vim.fn.expand(opts.log_dir or '~/.local/state/rime.nvim')
  local user_data_dir = vim.fn.expand(opts.user_data_dir or '~/.local/share/rime.nvim')
  vim.fn.mkdir(log_dir, 'p')
  vim.fn.mkdir(user_data_dir, 'p')
  config.shared_data_dir = opts.shared_data_dir
  config.user_data_dir = opts.user_data_dir or '~/.local/share/rime.nvim'
  config.log_dir = opts.log_dir or '~/.local/state/rime.nvim'

  rimeshim.Traits(
    vim.fn.expand(opts.shared_data_dir),
    user_data_dir,
    log_dir,
    'Rime',
    'nvim-rime',
    '0.0.1',
    'rime.nvim-rime',
    log_level.FATAL
  )
  -- librime 的 RimeInitialize 只启动引擎，不会编译词库/prism；
  -- 必须运行一次维护（部署）把 .table.bin/.prism.bin 编译到 user_data_dir/build，
  -- 否则引擎回退到内置的空 schema（.default），所有按键按 ASCII 直通。
  M.deploy()
  _userdata = rimeshim.Session()
end

---运行 librime 维护，把词库/方案编译到 user_data_dir/build。
---首次（build 目录为空）执行全量部署，之后只增量重建变更部分。
---@param force boolean? true 时强制全量重建（:RimeDeploy!）
---@return boolean 维护是否成功启动
function M.deploy(force)
  if not config.user_data_dir then return false end
  local build_dir = vim.fn.expand(config.user_data_dir) .. '/build'
  local first_run = force or vim.fn.glob(build_dir .. '/*.bin', false) == ''
  if first_run then
    vim.notify 'Rime: 首次使用，正在部署词库（仅需一次，请稍候）…'
  end
  local ok = rimeshim.start_maintenance(first_run)
  rimeshim.join_maintenance_thread()
  if first_run then
    vim.notify(ok and 'Rime: 词库部署完成' or 'Rime: 词库部署失败，请运行 :RimeDeploy 重试', ok and 'info' or 'error')
  end
  return ok
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
