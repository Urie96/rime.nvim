---wrap `rime.Session()` — IPC 客户端，取代旧的 rimeshim C 模块。
---
---通过 unix socket 与常驻的 rime-daemon（Rust 二进制）通信：
---每个 Neovim 实例一个连接 = 一个 librime session；daemon 由本模块
---懒启动（detached），最后一个客户端断开后 daemon 自动退出。
---
---协议：换行分隔的 JSON-RPC 2.0。请求为同步阻塞（vim.wait），
---按键路径与旧 C 模块同样会短暂阻塞主循环。
local M = {}

local state = {
  pipe = nil,
  connected = false,
  buffer = '',
  next_id = 0,
  pending = {}, -- id -> rec { done, value, err }
  traits = nil,
  spawned = false,
}

local SESSION_TIMEOUT_MS = 2000
local DEPLOY_TIMEOUT_MS = 300000 -- 首次部署可能较慢

-- daemon 在独立仓库编译安装，本插件不负责编译：
-- 优先 RIME_DAEMON_BIN，否则从 PATH 查找。
local function daemon_bin()
  local env = vim.env.RIME_DAEMON_BIN
  if env and vim.fn.filereadable(env) == 1 then return env end
  local p = vim.fn.exepath('rime-daemon')
  if p ~= '' and vim.fn.filereadable(p) == 1 then return p end
  return nil
end

local function socket_path()
  if state.traits and state.traits.socket then return state.traits.socket end
  local env_socket = vim.env.RIME_SOCKET
  if env_socket and env_socket ~= '' then return vim.fn.expand(env_socket) end
  local fallback = state.traits and state.traits.log_dir or vim.fn.expand('~/.local/state/rime.nvim')
  return vim.env.XDG_RUNTIME_DIR and (vim.env.XDG_RUNTIME_DIR .. '/rime-daemon.sock')
    or (fallback .. '/rime-daemon.sock')
end

local function build_env()
  local env = vim.fn.environ()
  -- 目录配置只在 setup 显式给出（或从环境变量解析得到）时才覆盖，
  -- 其余情况保留用户环境里的 RIME_*（vim.fn.environ() 已包含），由 daemon 兜底默认值。
  if state.traits.shared_data_dir then env.RIME_SHARED_DATA_DIR = state.traits.shared_data_dir end
  if state.traits.user_data_dir then env.RIME_USER_DATA_DIR = state.traits.user_data_dir end
  if state.traits.log_dir then env.RIME_LOG_DIR = state.traits.log_dir end
  env.RIME_SOCKET = socket_path()
  env.RIME_MIN_LOG_LEVEL = tostring(state.traits.min_log_level or 3)
  local arr = {}
  for k, v in pairs(env) do
    table.insert(arr, k .. '=' .. v)
  end
  return arr
end

local function spawn_daemon()
  local bin = daemon_bin()
  if not bin then
    vim.notify('rime.nvim: 未找到 rime-daemon，请先编译安装（见 README，可用 RIME_DAEMON_BIN 指定路径）', 'error')
    return false
  end
  local pid, err = vim.uv.spawn(bin, {
    args = {},
    env = build_env(),
    stdio = { ignore, ignore, ignore },
    detached = true,
  }, function() end)
  if not pid then
    vim.notify('rime.nvim: 启动 rime-daemon 失败: ' .. tostring(err), 'error')
    return false
  end
  state.spawned = true
  return true
end

---处理一条响应：按 id 投递给挂起的请求。
local function on_message(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= 'table' then return end
  local rec = state.pending[msg.id]
  if rec then
    if msg.error then
      rec.err = msg.error
    else
      rec.value = msg.result
    end
    rec.done = true
  end
end

local function pump_buffer(data)
  state.buffer = state.buffer .. (data or '')
  while true do
    local nl = state.buffer:find('\n', 1, true)
    if not nl then break end
    local line = state.buffer:sub(1, nl - 1)
    state.buffer = state.buffer:sub(nl + 1)
    if line ~= '' then on_message(line) end
  end
end

local function connect()
  if state.pipe and state.connected then return true end
  if state.pipe then
    pcall(function() state.pipe:close() end)
    state.pipe = nil
    state.connected = false
  end
  if not state.traits then return false end
  if not state.spawned then spawn_daemon() end

  local sock = socket_path()
  -- daemon 可能正在启动（socket 文件还没出现），重试 ~6s
  for _ = 1, 60 do
    local pipe = vim.uv.new_pipe(false)
    local ok, err = false, nil
    pipe:connect(sock, function(e) if e then err = e else ok = true end end)
    vim.wait(100, function() return ok or err ~= nil end)
    if ok then
      state.pipe = pipe
      state.connected = true
      state.buffer = ''
      pipe:read_start(function(e, data)
        if e then
          state.connected = false
        elseif data then
          pump_buffer(data)
        end
      end)
      return true
    end
    pcall(function() pipe:close() end)
    vim.wait(100)
  end
  vim.notify('rime.nvim: 无法连接 rime-daemon (' .. sock .. ')', 'error')
  return false
end

---同步 JSON-RPC 请求。超时或出错时返回 nil。
local function request(method, params, timeout_ms)
  if not connect() then return nil end
  state.next_id = state.next_id + 1
  local id = state.next_id
  local rec = { done = false }
  state.pending[id] = rec
  local payload = vim.json.encode { jsonrpc = '2.0', id = id, method = method, params = params or {} }
  local ok, werr = state.pipe:write(payload .. '\n')
  if not ok then
    state.pending[id] = nil
    state.connected = false
    return nil
  end
  -- fast_only=true：只处理 uv 回调（socket 数据），不执行排队的 nvim 事件
  -- （schedule/autocmd）。否则在 InsertCharPre 的 textlock 中，vim.wait 会
  -- 强制执行上一个按键排队的浮窗更新 → E565 改文本/改窗口报错。
  -- interval=5ms 轮询，让按键延迟接近旧 C shim 的同步调用。
  vim.wait(timeout_ms or SESSION_TIMEOUT_MS, function() return rec.done end, 5, true)
  if not rec.done then
    state.pending[id] = nil
    vim.notify(('rime.nvim: rime-daemon 请求超时 (%s)'):format(method), 'warn')
    return nil
  end
  if rec.err then
    vim.notify(('rime.nvim: rime-daemon 错误 (%s): %s'):format(method, rec.err.message or 'unknown'), 'warn')
    return nil
  end
  return rec.value
end

---保存用户 setup 传入的配置，并保证 daemon 可用（懒启动）。
function M.Traits(shared_data_dir, user_data_dir, log_dir, _, _, _, _, min_log_level)
  if state.traits then return end
  state.traits = {
    shared_data_dir = shared_data_dir,
    user_data_dir = user_data_dir,
    log_dir = log_dir,
    min_log_level = min_log_level,
  }
end

-- 每个连接对应 daemon 端一个 librime session；方法代理为 RPC。
local Session = {}

function Session:get_current_schema()
  return request('session_current_schema', {}, SESSION_TIMEOUT_MS)
end

function Session:select_schema(schema_id)
  return request('session_select_schema', { schema_id = schema_id }, SESSION_TIMEOUT_MS) == true
end

---@param code integer X11 keysym
---@param mask? integer
---@return boolean true = rime 未消费该键，需交给编辑器
function Session:process_key(code, mask)
  return request('session_process_key', { code = code, mask = mask or 0 }, SESSION_TIMEOUT_MS) == true
end

function Session:get_context()
  return request('session_get_context', {}, SESSION_TIMEOUT_MS)
end

function Session:get_commit()
  return request('session_get_commit', {}, SESSION_TIMEOUT_MS)
end

function Session:commit_composition()
  return request('session_commit_composition', {}, SESSION_TIMEOUT_MS) == true
end

function Session:clear_composition()
  request('session_clear_composition', {}, SESSION_TIMEOUT_MS)
end

function M.Session()
  return setmetatable({}, { __index = Session })
end

function M.get_schema_list()
  return request('schema_list', {}, SESSION_TIMEOUT_MS)
end

---@param full boolean
---@return boolean
function M.start_maintenance(full)
  return request('maintenance_start', { full = full == true }, SESSION_TIMEOUT_MS) == true
end

function M.join_maintenance_thread()
  return request('maintenance_join', {}, DEPLOY_TIMEOUT_MS) == true
end

function M.is_maintenance_mode()
  return request('maintenance_mode', {}, SESSION_TIMEOUT_MS) == true
end

return M
