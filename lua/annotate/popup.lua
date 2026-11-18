-- Floating markdown buffer to write or edit an annotation.
local M = {}

local config = require("annotate.config")

local function title(type_id)
  local t = config.type(type_id)
  local p = config.options.popup
  local hints = {}
  if p.submit then
    table.insert(hints, p.submit .. " save")
  end
  if p.cycle_type and #config.options.types > 1 then
    table.insert(hints, p.cycle_type .. " type")
  end
  if p.cancel then
    table.insert(hints, p.cancel .. " cancel")
  end
  return string.format(" %s  (%s) ", t and t.label or type_id:upper(), table.concat(hints, ", "))
end

---@param type_id string
---@param text? string existing text when editing
---@param on_submit fun(type_id: string, text: string)
function M.open(type_id, text, on_submit)
  local p = config.options.popup
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  if text and text ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  end

  local width = math.min(p.width, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = p.height,
    style = "minimal",
    border = p.border,
    title = title(type_id),
    title_pos = "left",
  })
  vim.wo[win].wrap = true

  local current = type_id

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
      table.remove(lines)
    end
    local body = table.concat(lines, "\n")
    close()
    if vim.trim(body) == "" then
      vim.notify("annotate: empty annotation, nothing saved", vim.log.levels.WARN)
      return
    end
    on_submit(current, body)
  end

  local function cycle()
    local types = config.options.types
    for i, t in ipairs(types) do
      if t.id == current then
        current = types[i % #types + 1].id
        break
      end
    end
    vim.api.nvim_win_set_config(win, { title = title(current), title_pos = "left" })
  end

  local o = { buffer = buf, nowait = true, silent = true }
  if p.submit then
    vim.keymap.set({ "n", "i" }, p.submit, submit, o)
  end
  if p.cancel then
    vim.keymap.set("n", p.cancel, close, o)
  end
  vim.keymap.set("n", "<Esc>", close, o)
  if p.cycle_type then
    vim.keymap.set("n", p.cycle_type, cycle, o)
  end
  if not text or text == "" then
    vim.cmd("startinsert")
  end
end

return M
