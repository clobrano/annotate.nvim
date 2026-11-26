local M = {}

local config = require("annotate.config")
local store = require("annotate.store")
local source = require("annotate.source")
local render = require("annotate.render")
local selection = require("annotate.selection")
local popup = require("annotate.popup")
local export = require("annotate.export")
local picker = require("annotate.picker")

local function notify(msg, level)
  vim.notify("annotate: " .. msg, level or vim.log.levels.INFO)
end

function M.setup(opts)
  config.setup(opts)
  render.render_all()
end

---Project root for commands that act on the whole project.
local function current_root()
  local src = source.resolve()
  return src and src.root or source.cwd_root()
end

---Annotate the visual selection (characters or lines), or the cursor line.
---@param cmd_range? table range from a user command
function M.add(cmd_range)
  local bufnr = vim.api.nvim_get_current_buf()
  local src, reason = source.resolve(bufnr)
  local range = selection.get(cmd_range)
  if not src then
    return notify("can't annotate this buffer: " .. reason, vim.log.levels.WARN)
  end
  if config.options.ephemeral_filetypes[vim.bo[bufnr].filetype] then
    store.set_ephemeral(src.root)
  end
  render.sync(bufnr)
  local a = vim.tbl_extend("force", range, {
    key = src.key,
    path = src.path,
    url = src.url,
    lang = vim.bo[bufnr].filetype,
  })
  a.code = render.text_at(bufnr, a)

  popup.open(nil, function(text)
    a.text = text
    store.add(src.root, a)
    render.render(bufnr)
  end)
end

function M.edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local a, src, reason = render.at_cursor()
  if not a then
    return notify(reason, vim.log.levels.WARN)
  end
  popup.open(a.text, function(text)
    a.text = text
    store.save(src.root)
    render.render(bufnr)
  end)
end

function M.delete()
  local bufnr = vim.api.nvim_get_current_buf()
  local a, src, reason = render.at_cursor()
  if not a then
    return notify(reason, vim.log.levels.WARN)
  end
  store.remove(src.root, a.id)
  render.render(bufnr)
end

---Jump to the next (dir=1) or previous (dir=-1) annotation in the buffer.
function M.jump(dir)
  local src = source.resolve()
  if not src then
    return
  end
  -- Positions in the store are stale until synced from the buffer's extmarks.
  render.sync(vim.api.nvim_get_current_buf())
  local cur = vim.api.nvim_win_get_cursor(0)
  local list = store.for_key(src.root, src.key)
  table.sort(list, function(x, y)
    return x.lnum < y.lnum or (x.lnum == y.lnum and (x.col or 0) < (y.col or 0))
  end)
  local pick
  for i = dir > 0 and 1 or #list, dir > 0 and #list or 1, dir do
    local a = list[i]
    local after = a.lnum > cur[1] or (a.lnum == cur[1] and (a.col or 0) > cur[2])
    local before = a.lnum < cur[1] or (a.lnum == cur[1] and (a.col or 0) < cur[2])
    if (dir > 0 and after) or (dir < 0 and before) then
      pick = a
      break
    end
  end
  if pick then
    vim.api.nvim_win_set_cursor(0, { pick.lnum, pick.col or 0 })
  end
end

---Quickfix/picker items for all annotations of the project. Remote
---annotations whose buffer is no longer open are marked invalid and get a
---url, so pickers can open their link in the browser.
---@param root string
---@return table[] items
local function list_items(root)
  local items = {}
  for _, a in ipairs(store.all(root)) do
    local item = {
      lnum = a.lnum,
      col = (a.col or 0) + 1,
      end_lnum = a.end_lnum,
      text = (a.text:gsub("\n", " ")),
      annotation = a,
    }
    if a.url then
      -- Remote content: only reachable while its buffer exists.
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local s = vim.api.nvim_buf_is_loaded(b) and source.resolve(b)
        if s and s.key == a.key then
          item.bufnr = b
          item.bufname = vim.api.nvim_buf_get_name(b)
        end
      end
      if not item.bufnr then
        item.text = item.text .. "  (" .. export.source(a) .. ")"
        item.valid = 0
        item.url = export.source(a)
      end
    else
      item.filename = root .. "/" .. a.path
    end
    table.insert(items, item)
  end
  return items
end

---All annotations of the project, in a picker (telescope or fzf-lua when
---installed, list.picker permitting) or the quickfix list.
function M.list()
  render.sync_all()
  local root = current_root()
  local items = list_items(root)
  if #items == 0 then
    return notify("no annotations in " .. vim.fn.fnamemodify(root, ":~"))
  end
  if picker.try(items, "Annotations") then
    return
  end
  vim.fn.setqflist({}, " ", { title = "Annotations", items = items })
  vim.cmd("copen")
end

---Markdown of the project's annotations, or only the current buffer's with
---scope = "buffer".
---@param scope? "buffer"
---@return string|nil text, string root, Annotation[] list
function M.build(scope)
  render.sync_all()
  local src, reason = source.resolve()
  local root = src and src.root or source.cwd_root()
  local list = store.all(root)
  if scope == "buffer" then
    if not src then
      notify("can't scope to this buffer: " .. reason, vim.log.levels.WARN)
      return nil, root, list
    end
    list = store.for_key(root, src.key)
  end
  if #list == 0 then
    return nil, root, list
  end
  return export.build(list), root, list
end

---@param target? "clipboard"|"file"|"tmux"
---@param scope? "buffer"
function M.export(target, scope)
  target = target or "clipboard"
  local deliver = export.targets[target]
  if not deliver then
    return notify("unknown export target " .. target, vim.log.levels.ERROR)
  end
  local text, root, list = M.build(scope)
  if not text then
    return notify("no annotations to export")
  end
  local n = #list
  deliver(text, root, function(ok, msg)
    if not ok then
      return notify("export failed: " .. msg, vim.log.levels.ERROR)
    end
    if config.options.export.clear_after_export then
      store.archive(root, scope == "buffer" and list or nil)
      render.render_all()
      msg = msg .. ", then archived"
    end
    notify(string.format("%d annotation%s %s", n, n == 1 and "" or "s", msg))
  end, n)
end

---Show the export in a split: the project's annotations, or only the current
---buffer's with scope = "buffer".
---@param scope? "buffer"
function M.preview(scope)
  local text = M.build(scope)
  if not text then
    return notify("no annotations to export")
  end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
end

---Archive and remove every annotation of the project.
function M.clear()
  local root = current_root()
  local n = store.archive(root)
  render.render_all()
  notify(string.format("archived %d annotation%s", n, n == 1 and "" or "s"))
end

return M
