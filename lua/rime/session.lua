---wrap `rime.Session()`
local rimeshim = require 'rimeshim'
local M = {}

---@class RimeSessionOptions
---@field shared_data_dir string
---@field user_data_dir? string
---@field log_dir? string

---@class RimeSchema
---@field schema_id string
---@field name string

---@class RimeCommit
---@field text string

---@class RimeComposition
---@field length integer
---@field cursor_pos integer
---@field sel_start integer
---@field sel_end integer
---@field preedit string

---@class RimeCandidate
---@field text string
---@field comment? string

---@class RimeMenu
---@field page_size integer
---@field page_no integer
---@field is_last_page boolean
---@field highlighted_candidate_index integer
---@field num_candidates integer
---@field candidates RimeCandidate[]
---@field select_keys? string

---@class RimeContext
---@field composition RimeComposition
---@field menu RimeMenu

local _userdata

-- 保存用户 setup 时传入的配置
local config = {}

local log_level = { INFO = 0, WARNING = 1, ERROR = 2, FATAL = 3 }

---Initialize rime session (only once).
---@param opts RimeSessionOptions
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

---返回当前方案 ID；会话无效时返回 nil。
---@return string?
function M.get_current_schema() return _userdata:get_current_schema() end

---将一个 X11 keysym 及修饰键掩码交给 librime 处理。
---@param code integer
---@param mask? integer
---@return boolean
function M.process_key(code, mask) return _userdata:process_key(code, mask) end

---获取当前输入上下文；会话无效时返回 nil。
---@return RimeContext?
function M.get_context() return _userdata:get_context() end

---读取尚未取走的上屏文本；没有待取文本时返回 nil。
---@return RimeCommit?
function M.get_commit() return _userdata:get_commit() end

---提交当前正在编辑的 composition。
---@return boolean
function M.commit_composition() return _userdata:commit_composition() end

---清除当前 composition。
function M.clear_composition() return _userdata:clear_composition() end

---@type fun(): RimeSchema[]?
M.get_schema_list = rimeshim.get_schema_list

---返回当前方案的显示名称。
---@return string
function M.get_schema_name()
  local schemas = M.get_schema_list()
  local schema_id = M.get_current_schema()
  for _, schema in ipairs(schemas) do
    if schema.schema_id == schema_id then return schema.name end
  end
  return ''
end

---提交当前 composition 并返回上屏文本。
---@return string
function M.get_commit_text()
  local text = ''
  if M.commit_composition() then
    local commit = M.get_commit()
    if commit then text = commit.text end
  end
  return text
end

return M
