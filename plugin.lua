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
  local plugin_path = fs.path(workspace.getAbsolutePath(config.get('Lua.runtime.plugin')))

  ---@type string
  local new_path = (plugin_path:parent_path() / "?.lua"):string()
  if not package.path:find(new_path, 1, true) then
    package.path = package.path..";"..new_path
  end
end

---@class Diff
---@field start  integer # The number of bytes at the beginning of the replacement
---@field finish integer # The number of bytes at the end of the replacement
---@field text   string  # What to replace

local expression_as_string
local identifier_as_string
local ignored_by_language_server
local ignored_by_preprocessor
local type_constructors
local delegates
local parse_hash_lines
local pragma_once

---@param  uri  string # The uri of file
---@param  text string # The content of file
---@return nil|Diff[]
function OnSetText(uri, text)
  if text:sub(1, 4) == "--##" then return end

  local diffs = {}

  expression_as_string(uri, text, diffs)
  identifier_as_string(uri, text, diffs)
  ignored_by_language_server(uri, text, diffs)
  ignored_by_preprocessor(uri, text, diffs)
  type_constructors(uri, text, diffs)
  delegates(uri, text, diffs)
  parse_hash_lines(uri, text, diffs)
  pragma_once(uri, text, diffs)

  return #diffs ~= 0 and diffs
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
---@param diffs Diff[]
---@param chain_diff ChainDiffElem[]
local function add_chain_diff(diffs, chain_diff)
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

---is the given position commented out
---(only checks one line comments)
---@param text string
---@param position number
---@return boolean
local function commented(text, position)
  return not not text:sub(1, position):find("%-%-[^\n]*$")
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function expression_as_string(uri, text, diffs)
  ---@type string|number
  for s, f in text:gmatch("()%$e%b()()") do
    add_diff(diffs, s, s + 3, "")
    add_diff(diffs, f - 1, f, "")
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function identifier_as_string(uri, text, diffs)
  ---@type string|number
  for s, f in text:gmatch("()$()[a-zA-Z_][a-zA-Z0-9_]*") do
    if not text:match("^[epl]%(", f) then
      add_diff(diffs, s, f, "")
    end
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function ignored_by_language_server(uri, text, diffs)
  ---@type string|number
  for s, f in text:gmatch("()%$p%b()()") do
    add_diff(diffs, s, f, "")
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function ignored_by_preprocessor(uri, text, diffs)
  ---@type string|number
  for s, f in text:gmatch("()%$l%b()()") do
    add_diff(diffs, s, s + 3, "")
    add_diff(diffs, f - 1, f, "")
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function pragma_once(uri, text, diffs)
  ---@type string|number
  local s, f = text:match("()#pragma once()")
  if s then
    for _, diff in ipairs(diffs) do
      if diff.start == s then
        diff.finish = f - 1
      end
    end
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function type_constructors(uri, text, diffs)
  local need_global = false
  local classes = {}

  ---@type string|number
  for name in text:gmatch("%-%-%-@class%s*([^%s]+)") do
    local id = to_identifier(name)
    classes[#classes+1] = "---@param _ "..name.."\n---@return "..name.."\nfunction __new."..id.."(_) end\n"
    need_global = true
  end

  ---@type string|number
  for s_new, f_new, s_name, name, f_name, whitespace, parenth
  in
    text:gmatch("()new()%s+()([^%s({}),]+)()(%s*)([({]?)")
  do
    if parenth ~= "" or whitespace:find("\n", 1, true) then
      add_chain_diff(diffs, {
        {i = s_new, text = "__new"},
        {i = f_new, text = "."},
        {i = s_name, text = to_identifier(name)},
        {i = f_name},
      })
      need_global = true
    end
  end

  if need_global then
    add_diff(diffs, 1, 1, "__new={}\n"..table.concat(classes))
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function delegates(uri, text, diffs)
  ---@type number
  for s_param, f_param, s_body, f_body
  in
    text:gmatch("()[a-zA-Z_][a-zA-Z0-9_]*()%s*=>%s*()%b()()")
  do
    if not commented(text, s_param) then
      add_diff(diffs, s_param, s_param, " function(")
      add_diff(diffs, f_param, s_body + 1, ")return\n")
      add_diff(diffs, f_body - 1, f_body, ";end\n")
    end
  end

  ---@type number
  for s_param, f_param, s_body, f_body
  in
    text:gmatch("()[a-zA-Z_][a-zA-Z0-9_]*()%s*=>%s*()%b{}()")
  do
    if not commented(text, s_param) then
      add_diff(diffs, s_param, s_param, " function(")
      add_diff(diffs, f_param, s_body + 1, ")")
      add_diff(diffs, f_body - 1, f_body, ";end\n")
    end
  end

  ---@type number
  for s_param, f_param, s_body, f_body
  in
    text:gmatch("()%([^())]*%)()%s*=>%s*()%b()()")
  do
    if not commented(text, s_param) then
      add_diff(diffs, s_param, s_param, " function")
      add_diff(diffs, f_param, s_body + 1, "return\n")
      add_diff(diffs, f_body - 1, f_body, ";end\n")
    end
  end

  ---@type number
  for s_param, f_param, s_body, f_body
  in
    text:gmatch("()%([^())]*%)()%s*=>%s*()%b{}()")
  do
    if not commented(text, s_param) then
      add_diff(diffs, s_param, s_param, " function")
      add_diff(diffs, f_param, s_body + 1, "")
      add_diff(diffs, f_body - 1, f_body, ";end\n")
    end
  end
end

-- TODO: use better variable names

---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
---@param start number @ The index to start searching at
---@param finish number @ The index to stop searching at
local function parse_dollar_paren(diffs, text, start, finish)
  local chunk = text:sub(start, finish)
  local offset = start - 1
  ---@type string|number
  for s_term, f_term in chunk:gmatch("()$%b()()") do
    add_diff(diffs, offset + s_term, offset + s_term + 2, "")
    add_diff(diffs, offset + f_term - 1, offset + f_term, "")
  end
end

---@param uri string @ The uri of file
---@param text string @ The content of file
---@param diffs Diff[] @ The diffs to add more diffs to
function parse_hash_lines(uri, text, diffs)
  local s = 1
  while true do
    ---@type string|number
    local ss, e, s_hashes, hashes, eol = string.find(text, "^%s*()(#+)[^\n]*()\n?", s)
    if e then
      add_diff(diffs, s, (#hashes > 1) and eol or s_hashes + 1, "")
    else
      ---@type string|number
      ss, e, s_hashes, hashes, eol = string.find(text, "\n%s*()(#+)[^\n]*()\n?", s)
      parse_dollar_paren(diffs, text, s, ss)
      if not e then break end
      add_diff(diffs, ss + 1, (#hashes > 1) and eol or s_hashes + 1, "")
    end
    s = e + 1
  end
end
