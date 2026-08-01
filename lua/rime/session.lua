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
  -- daemon 启动时会自动部署，这里只需等待部署完成（首次使用较慢）。
  M.wait_deployed()
  _userdata = rimeshim.Session()
end

---等待 daemon 完成启动时的自动部署。
---首次使用（build/ 为空）时 daemon 会全量编译词库，需要一段时间；
---daemon 常驻后再次连接时部署早已完成，此函数立即返回。
---@return boolean 部署是否已完成
function M.wait_deployed()
  if not rimeshim.is_maintenance_mode() then return true end
  vim.notify 'Rime: 首次使用，正在部署词库（仅需一次，请稍候）…'
  local t = vim.uv.hrtime()
  while rimeshim.is_maintenance_mode() do
    if (vim.uv.hrtime() - t) / 1e9 > 300 then
      vim.notify('Rime: 词库部署超时，请运行 :RimeDeploy 重试', 'error')
      return false
    end
    vim.wait(200)
  end
  vim.notify('Rime: 词库部署完成', 'info')
  return true
end

---运行 librime 维护（手动部署，:RimeDeploy / :RimeDeploy!）。
---daemon 启动时已自动部署一次；此函数用于源文件变更后手动重建。
---@param force boolean? true 时强制全量重建
---@return boolean 维护是否成功启动
function M.deploy(force)
  if not config.user_data_dir then return false end
  local ok = rimeshim.start_maintenance(force == true)
  rimeshim.join_maintenance_thread()
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
