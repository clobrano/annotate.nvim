-- Works out what a buffer is: which project it belongs to, the key its
-- annotations are stored under, and how to point an agent at it.
local M = {}

local uv = vim.uv or vim.loop

---@class AnnotateSource
---@field root string  project root (where the store and the file export live)
---@field key string   stable id of the buffer's content inside the project
---@field path string  path shown to the agent (relative to root when possible)
---@field url? string  web link to the file, without the line anchor (remote buffers)

local function realpath(p)
  return uv.fs_realpath(p) or p
end

---Git root containing `dir` (a .git dir or file, so worktrees work too).
---@param dir string
---@return string|nil
function M.git_root(dir)
  local found = vim.fs.find(".git", { upward = true, path = dir, limit = 1 })[1]
  return found and realpath(vim.fs.dirname(found)) or nil
end

---@param root string
---@param abs string
---@return string
local function relative(root, abs)
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return abs
end

---Root for buffers that are not files on disk.
---@return string
function M.cwd_root()
  local cwd = realpath(vim.fn.getcwd())
  return M.git_root(cwd) or cwd
end

-- Built-in resolver: gh-review.nvim diff buffers (gh-review://LEFT|RIGHT/<path>).
local function gh_review(bufnr)
  local side, path = vim.api.nvim_buf_get_name(bufnr):match("^gh%-review://(%u+)/(.+)$")
  if not path then
    return nil
  end
  local ok, state = pcall(require, "gh_review.state")
  if not ok then
    return nil, "gh-review buffer, but gh_review.state is not available"
  end
  local oid
  if side == "LEFT" then
    oid = state.get_merge_base_oid()
    if not oid or oid == "" then
      oid = state.get_base_oid()
    end
  else
    oid = state.get_head_oid()
  end
  local owner, name = state.get_owner(), state.get_name()
  if not oid or oid == "" or not owner or owner == "" then
    return nil, "gh-review has no pull request loaded"
  end
  local host = state.get_host()
  if not host or host == "" then
    host = "github.com"
  end
  return {
    root = M.cwd_root(),
    key = string.format("%s@%s", path, oid),
    path = path,
    url = string.format("https://%s/%s/%s/blob/%s/%s", host, owner, name, oid, path),
  }
end

local builtin = { gh_review }

---@param bufnr? integer
---@return AnnotateSource|nil, string|nil reason
function M.resolve(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid buffer"
  end

  local resolvers = vim.list_extend(vim.list_slice(require("annotate.config").options.resolvers), builtin)
  local reason
  for _, resolve in ipairs(resolvers) do
    local src, why = resolve(bufnr)
    if src then
      src.key = src.key or src.path
      return src
    end
    reason = reason or why
  end
  if reason then
    return nil, reason
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local bt = vim.bo[bufnr].buftype
  if bt ~= "" and bt ~= "acwrite" then
    return nil, string.format("not a file buffer (buftype=%s)", bt)
  end
  if name == "" then
    return nil, "the buffer has no name; save it first"
  end
  if name:match("^%a[%w+.-]*://") then
    return nil, string.format("no resolver for %q (see `resolvers` in the README)", name:match("^%a[%w+.-]*://"))
  end

  local abs = realpath(vim.fn.fnamemodify(name, ":p"))
  local root = M.git_root(vim.fs.dirname(abs))
  if not root then
    local cwd = realpath(vim.fn.getcwd())
    root = abs:sub(1, #cwd + 1) == cwd .. "/" and cwd or vim.fs.dirname(abs)
  end
  local rel = relative(root, abs)
  return { root = root, key = rel, path = rel }
end

return M
