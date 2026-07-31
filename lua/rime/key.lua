local Key = {
  code = (' '):byte(),
  mask = 0,
}

---@return string
function Key:tostring()
  if self.mask ~= 0 or self.code < (' '):byte() or self.code > ('~'):byte() then return '' end
  return string.char(self.code)
end

local M = {
  vim_to_rime = {
    pageup = 'Page_Up',
    pagedown = 'Page_Down',
    esc = 'Escape',
    bs = 'BackSpace',
    del = 'Delete',
  },
  aliases = {
    ['<nul>'] = '<c-space>',
    ['<c-@>'] = '<c-space>',
    ['<c-h>'] = '<bs>',
    ['<c-i>'] = '<tab>',
    ['<nl>'] = '<c-j>',
    ['<c-m>'] = '<return>',
    ['<enter>'] = '<return>',
    ['<cr>'] = '<return>',
    ['<c-[>'] = '<esc>',
    ['<space>'] = ' ',
    ['<lt>'] = '<',
    ['<bslash>'] = '\\',
    ['<bar>'] = '|',
    ['<c-^>'] = '<c-6>',
    ['<c-_>'] = '<c-->',
    ['<c-/>>'] = '<c-->',
  },
  modifiers = {
    S = 1,
    C = 4,
    A = 8,
    M = 8,
  },
  keys = {
    ['BackSpace'] = 65288,
    ['Delete'] = 65535,
    ['Down'] = 65364,
    ['End'] = 65367,
    ['Escape'] = 65307,
    ['F1'] = 65470,
    ['F10'] = 65479,
    ['F11'] = 65480,
    ['F12'] = 65481,
    ['F13'] = 65482,
    ['F14'] = 65483,
    ['F15'] = 65484,
    ['F16'] = 65485,
    ['F17'] = 65486,
    ['F18'] = 65487,
    ['F19'] = 65488,
    ['F2'] = 65471,
    ['F20'] = 65489,
    ['F21'] = 65490,
    ['F22'] = 65491,
    ['F23'] = 65492,
    ['F24'] = 65493,
    ['F25'] = 65494,
    ['F26'] = 65495,
    ['F27'] = 65496,
    ['F28'] = 65497,
    ['F29'] = 65498,
    ['F3'] = 65472,
    ['F30'] = 65499,
    ['F31'] = 65500,
    ['F32'] = 65501,
    ['F33'] = 65502,
    ['F34'] = 65503,
    ['F35'] = 65504,
    ['F4'] = 65473,
    ['F5'] = 65474,
    ['F6'] = 65475,
    ['F7'] = 65476,
    ['F8'] = 65477,
    ['F9'] = 65478,
    ['Home'] = 65360,
    ['Insert'] = 65379,
    ['Left'] = 65361,
    ['Page_Down'] = 65366,
    ['Page_Up'] = 65365,
    ['Return'] = 65293,
    ['Right'] = 65363,
    ['Tab'] = 65289,
    ['Up'] = 65362,
  },
}

---@param key table?
---@return table
function M.new(key)
  key = key or {}
  setmetatable(key, { __tostring = Key.tostring, __index = Key })
  return key
end

---@param name string
---@return table
function M.from_vim(name)
  name = M.aliases[name:lower()] or name
  if #name == 1 then return M.new { code = name:byte() } end
  name = name:sub(2, -2):lower()
  local mask = 0
  for prefix in name:gmatch '([^-])-' do
    mask = mask + M.modifiers[prefix:upper()]
  end
  name = name:match '[^-]+$' or '-'
  name = M.aliases['<' .. name:lower() .. '>'] or name
  if mask == M.modifiers.C then name = name:lower() end
  if #name == 1 then return M.new { code = name:byte(), mask = mask } end
  return M.new { code = M.convert(name:lower()), mask = mask }
end

---@param name string
---@return integer
function M.convert(name) return M.keys[M.vim_to_rime[name] or (name:sub(1, 1):upper() .. name:sub(2):lower())] end

return M
