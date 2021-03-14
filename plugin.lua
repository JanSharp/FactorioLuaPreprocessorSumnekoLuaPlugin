--##

-- (this should probably be in some better location, maybe the readme? i'm not sure)
-- what do the different prefixes for gmatch results mean:
-- s = start, f = finish, p = position, no prefix = an actual string capture

-- allow for require to search relative to this plugin file
-- open for improvements!
if not _G.__lua_preprocessor_plugin_initialized then
  _G.__lua_preprocessor_plugin_initialized = true

  ---@type table
  local config = require("config")
  ---@type table
  local fs = require("bee.filesystem")
  ---@type table
  local workspace = require("workspace")

  ---@type userdata
  local plugin_path = fs.path(config.config.runtime.plugin)
  if plugin_path:is_relative() then
    plugin_path = fs.path(workspace.path) / plugin_path
  end

  ---@type string
  local new_path = (plugin_path:parent_path() / "?.lua"):string()
  if not package.path:find(new_path, 1, true) then
    package.path = package.path..";"..new_path
  end
end

local preprocessor = require("preprocessor")

---@class Diff
---@field start  integer # The number of bytes at the beginning of the replacement
---@field finish integer # The number of bytes at the end of the replacement
---@field text   string  # What to replace

local type_constructors

---@param  uri  string # The uri of file
---@param  text string # The content of file
---@return nil|Diff[]
function OnSetText(uri, text)
  if text:sub(1, 4) == "--##" then return end

  local diffs = {}

  type_constructors(uri, text, diffs)
  -- if #diffs ~= 0 and diffs then
  --   return (#diffs).." "..uri
  -- end
  return #diffs ~= 0 and diffs

  -- local result = preprocessor.preprocess_in_memory(text)
  -- return result ~= text and result
end

---@param diffs Diff[]
---@param start number
---@param finish number
---@param replacement string
local function add_diff(diffs, start, finish, replacement)
  diffs[#diffs+1] = {
    start = start,
    finish = finish - 1,
    text = replacement,
  }
end

---@class ChainDiffElem
---@field i number @ index within the text of the file
---@field text nil|string @ text replacing from this elem's `i` including to the next elem's `i` excluding. When nil no diff will be created. If the last elem has `text` it will treat it as if there was another elem after with with the same `i`

---creates diffs according to the chain_diff. See ChainDiffElem class description for how it works
---@param chain_diff ChainDiffElem[]
---@param diffs Diff[]
local function add_chain_diff(chain_diff, diffs)
  local prev_chain_diff_elem = chain_diff[1]
  if not prev_chain_diff_elem then return end
  for i = 2, #chain_diff do
    local chain_diff_elem = chain_diff[i]
    if prev_chain_diff_elem.text then
      diffs[#diffs+1] = {
        start = prev_chain_diff_elem.i,
        finish = chain_diff_elem.i - 1, -- finish is treated as including, which we don't want
        text = prev_chain_diff_elem.text,
      }
    end
    prev_chain_diff_elem = chain_diff_elem
  end
  if prev_chain_diff_elem.text then
    diffs[#diffs+1] = {
      start = prev_chain_diff_elem.i,
      finish = prev_chain_diff_elem.i - 1,
      text = prev_chain_diff_elem.text,
    }
  end
end

---extends the text of a ChainDiffElem or setting it if it is nil
---@param elem ChainDiffElem
---@param text string
local function extend_chain_diff_elem_text(elem, text)
  if elem.text then
    elem.text = elem.text.. text
  else
    elem.text = text
  end
end

---@param str string
---@return string
local function to_identifier(str)
  return str:gsub("[^a-zA-Z0-9_]","_")
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function type_constructors(uri, text, diffs)
  local need_global = false

  ---@type string|number
  for s, name
  in
    text:gmatch("()%-%-%-@class%s*([^%s]+)")
  do
    local id = to_identifier(name)
    add_diff(diffs, s, s, "\n---@param _ "..name.."\n---@return "..name.."\nfunction __new."..id.."(_) end\n")
    need_global = true
  end

  ---@type string|number
  for s_new, f_new, s_name, name, f_name, whitespace, parenth
  in
    text:gmatch("()new()%s+()([^%s({}),]+)()(%s*)([({]?)")
  do
    if parenth ~= "" or whitespace:find("\n", 1, true) then
      add_chain_diff({
        {i = s_new, text = "__new"},
        {i = f_new, text = "."},
        {i = s_name, text = to_identifier(name)},
        {i = f_name},
      }, diffs)
      need_global = true
    end
  end

  if need_global then
    add_diff(diffs, 1, 1, "__new={}\n")
  end
end