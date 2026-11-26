-- :Annotate list in telescope or fzf-lua when one of them is installed,
-- quickfix otherwise. See init.list().
local M = {}

local config = require("annotate.config")

---One line per annotation: "where  comment". The where part is relative
---path:line for files, buffer name:line for loaded remote buffers. Remote
---annotations whose buffer is gone already carry their link in text.
---@param item table quickfix item built by init.list()
---@return string
local function display(item)
  local where
  if item.filename then
    where = vim.fn.fnamemodify(item.filename, ":~:.") .. ":" .. item.lnum
  elseif item.bufnr then
    where = vim.fn.fnamemodify(item.bufname, ":t") .. ":" .. item.lnum
  end
  if not where then
    return item.text
  end
  return string.format("%s: %s", where, item.text)
end

---Go where the item points. Remote items whose buffer is gone open their
---link in the browser instead.
---@param item table
function M._jump(item)
  if item.url then
    if vim.ui and vim.ui.open then
      return vim.ui.open(item.url)
    end
    return vim.notify("annotate: " .. item.url)
  end
  if item.bufnr then
    vim.api.nvim_win_set_buf(0, item.bufnr)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
  end
  vim.api.nvim_win_set_cursor(0, { item.lnum, item.col - 1 })
end

---@param items table[]
---@param title string
---@return boolean handled
local function telescope(items, title)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return false
  end
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local conf = require("telescope.config").values
  pickers
    .new({}, {
      prompt_title = title,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local d = display(item)
          return { value = item, display = d, ordinal = d, path = item.filename, lnum = item.lnum }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.vim_buffer_cat.new({}),
      attach_mappings = function(prompt_bufnr)
        local actions = require("telescope.actions")
        local state = require("telescope.actions.state")
        actions.select_default:replace(function()
          local item = state.get_selected_entry().value
          actions.close(prompt_bufnr)
          M._jump(item)
        end)
        return true
      end,
    })
    :find()
  return true
end

---@param items table[]
---@param title string
---@return boolean handled
local function fzf_lua(items, title)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end
  local item_of = {}
  local entries = {}
  for _, item in ipairs(items) do
    local d = display(item)
    item_of[d] = item
    table.insert(entries, d)
  end
  fzf.fzf_exec(entries, {
    prompt = title .. "> ",
    actions = {
      ["default"] = function(selected)
        M._jump(item_of[selected[1]])
      end,
    },
  })
  return true
end

---Show the items in a picker. Returns true when one of them did.
---@param items table[]
---@param title string
---@return boolean handled
function M.try(items, title)
  local pref = config.options.list.picker
  if pref == false or pref == "quickfix" then
    return false
  end
  if (pref == "telescope" or pref == "auto") and telescope(items, title) then
    return true
  end
  if (pref == "fzf" or pref == "auto") and fzf_lua(items, title) then
    return true
  end
  return false
end

return M
