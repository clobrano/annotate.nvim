-- One JSON file per project root under config.data_dir.
local M = {}

local config = require("annotate.config")

---@class Annotation
---@field id string
---@field key string         source key (see source.lua)
---@field path string        path shown in the export
---@field url? string        web link without anchor, for buffers with no file on disk
---@field text string        the comment
---@field code string        the annotated text, used to find the spot again
---@field lang string        filetype, for the code fence
---@field lnum integer       1-based
---@field col integer        0-based byte, start
---@field end_lnum integer   1-based
---@field end_col integer    0-based byte, exclusive (charwise only)
---@field linewise boolean
---@field created_at integer

---@type table<string, Annotation[]> annotations by root
local cache = {}
local counter = 0

local function file_for(root)
  return string.format("%s/%s.json", config.options.data_dir, (root:gsub("[/\\:]", "%%")))
end

---@param root string
---@return Annotation[]
function M.all(root)
  if cache[root] then
    return cache[root]
  end
  local list = {}
  local f = io.open(file_for(root), "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" and type(data.annotations) == "table" then
      list = data.annotations
    else
      vim.notify("annotate: could not read " .. file_for(root), vim.log.levels.ERROR)
    end
  end
  cache[root] = list
  return list
end

---@param root string
function M.save(root)
  local list = cache[root] or {}
  vim.fn.mkdir(config.options.data_dir, "p")
  local path = file_for(root)
  if #list == 0 then
    os.remove(path)
    return
  end
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode({ version = 1, root = root, annotations = list }))
  f:close()
end

---@param root string
---@param key string
---@return Annotation[]
function M.for_key(root, key)
  local out = {}
  for _, a in ipairs(M.all(root)) do
    if a.key == key then
      table.insert(out, a)
    end
  end
  return out
end

---@param root string
---@param a Annotation
---@return Annotation
function M.add(root, a)
  counter = counter + 1
  a.id = string.format("%d-%d", os.time(), counter)
  a.created_at = os.time()
  table.insert(M.all(root), a)
  M.save(root)
  return a
end

---@param root string
---@param id string
function M.remove(root, id)
  local list = M.all(root)
  for i, a in ipairs(list) do
    if a.id == id then
      table.remove(list, i)
      break
    end
  end
  M.save(root)
end

---Move annotations of the project to data_dir/archive and remove them from
---the store. With a {subset}, only those annotations are moved.
---@param root string
---@param subset? Annotation[]
---@return integer archived
function M.archive(root, subset)
  local list = M.all(root)
  if subset then
    local ids = {}
    for _, a in ipairs(subset) do
      ids[a.id] = true
    end
    subset = vim.tbl_filter(function(a)
      return ids[a.id]
    end, list)
    cache[root] = vim.tbl_filter(function(a)
      return not ids[a.id]
    end, list)
    list = subset
  else
    cache[root] = {}
  end
  local n = #list
  if n == 0 then
    return 0
  end
  local dir = config.options.data_dir .. "/archive"
  vim.fn.mkdir(dir, "p")
  local name = vim.fn.fnamemodify(file_for(root), ":t:r")
  local f = io.open(string.format("%s/%s-%s.json", dir, name, os.date("%Y%m%dT%H%M%S")), "w")
  if f then
    f:write(vim.json.encode({ version = 1, root = root, annotations = list }))
    f:close()
  end
  M.save(root)
  return n
end

-- For tests.
function M._reset()
  cache = {}
end

return M
