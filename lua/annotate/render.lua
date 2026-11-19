-- Draws annotations with extmarks and keeps them attached to their text.
local M = {}

local config = require("annotate.config")
local store = require("annotate.store")
local source = require("annotate.source")

M.ns = vim.api.nvim_create_namespace("annotate")

---@type table<integer, table<string, integer>> range extmark id by buffer and annotation id
local tracked = {}

---Text currently covered by a range.
---@param bufnr integer
---@param a Annotation
---@return string
function M.text_at(bufnr, a)
  local ok, lines
  if a.linewise then
    ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, a.lnum - 1, a.end_lnum, true)
  else
    ok, lines = pcall(vim.api.nvim_buf_get_text, bufnr, a.lnum - 1, a.col, a.end_lnum - 1, a.end_col, {})
  end
  return ok and table.concat(lines, "\n") or ""
end

---Find `a.code` in the buffer, closest to where it used to be.
---@return integer|nil lnum, integer|nil col
local function search(bufnr, a)
  if not a.code or vim.trim(a.code) == "" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local code = vim.split(a.code, "\n", { plain = true })
  local n = #code
  local best, best_dist

  local function consider(row, col)
    local dist = math.abs(row - a.lnum) * 10000 + math.abs(col - a.col)
    if not best_dist or dist < best_dist then
      best, best_dist = { row, col }, dist
    end
  end

  for row = 1, #lines - n + 1 do
    if a.linewise then
      local match = true
      for i = 1, n do
        if lines[row + i - 1] ~= code[i] then
          match = false
          break
        end
      end
      if match then
        consider(row, 0)
      end
    elseif n == 1 then
      local init = 1
      while true do
        local s = lines[row]:find(code[1], init, true)
        if not s then
          break
        end
        consider(row, s - 1)
        init = s + 1
      end
    else
      local first = lines[row]
      if first:sub(-#code[1]) == code[1] then
        local match = true
        for i = 2, n - 1 do
          if lines[row + i - 1] ~= code[i] then
            match = false
            break
          end
        end
        if match and lines[row + n - 1]:sub(1, #code[n]) == code[n] then
          consider(row, #first - #code[1])
        end
      end
    end
  end
  if best then
    return best[1], best[2]
  end
end

---Make sure the annotation points at its text. Moves it (and saves) when the
---text was found elsewhere.
---@return boolean found
local function anchor(bufnr, root, a)
  if M.text_at(bufnr, a) == a.code then
    return true
  end
  local lnum, col = search(bufnr, a)
  if not lnum then
    return false
  end
  local code = vim.split(a.code, "\n", { plain = true })
  local height = #code - 1
  a.end_lnum = lnum + height
  if not a.linewise then
    a.end_col = height == 0 and col + #code[1] or #code[#code]
  end
  a.lnum, a.col = lnum, col
  store.save(root)
  return true
end

---Longest prefix of `word` that fits in `width` display cells, at least one
---character. Returns the prefix and the rest.
---@return string prefix, string rest
local function take_prefix(word, width)
  local prefix = ""
  for _, code in utf8.codes(word) do
    local ch = utf8.char(code)
    if prefix ~= "" and vim.fn.strdisplaywidth(prefix) + vim.fn.strdisplaywidth(ch) > width then
      return prefix, word:sub(#prefix + 1)
    end
    prefix = prefix .. ch
  end
  return prefix, ""
end

---Greedy word wrap at `width` display columns. A word longer than the width
---is hard-split.
---@param line string
---@param width integer
---@return string[]
local function wrap_line(line, width)
  local out = {}
  local cur = ""
  local function flush()
    table.insert(out, cur)
    cur = ""
  end
  for word in line:gmatch("%S+") do
    if cur ~= "" and vim.fn.strdisplaywidth(cur) + 1 + vim.fn.strdisplaywidth(word) > width then
      flush()
    end
    while vim.fn.strdisplaywidth(word) > width do
      if cur ~= "" then
        flush()
      end
      local prefix
      prefix, word = take_prefix(word, width)
      table.insert(out, prefix)
    end
    cur = cur == "" and word or (cur .. " " .. word)
  end
  flush()
  return out
end

---@param text string
---@param label string
---@param indent integer
---@param hl string
local function box(text, label, indent, hl)
  local pad = string.rep(" ", indent)
  local body = {}
  local wrap = config.options.display.wrap
  if wrap then
    local w = math.max(16, wrap - indent)
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      vim.list_extend(body, wrap_line(l, w))
    end
  else
    body = vim.split(text, "\n", { plain = true })
  end
  local width = vim.fn.strdisplaywidth(label) + 4
  for _, l in ipairs(body) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local head = "─ " .. label .. " "
  local out = { { { pad .. "╭" .. head .. string.rep("─", width + 2 - vim.fn.strdisplaywidth(head)) .. "╮", hl } } }
  for _, l in ipairs(body) do
    table.insert(out, { { pad .. "│ " .. l .. string.rep(" ", width - vim.fn.strdisplaywidth(l)) .. " │", hl } })
  end
  table.insert(out, { { pad .. "╰" .. string.rep("─", width + 2) .. "╯", hl } })
  return out
end

local function indent_of(line)
  return vim.fn.strdisplaywidth(line:match("^%s*"))
end

---@param bufnr? integer
function M.render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  tracked[bufnr] = {}
  local src = source.resolve(bufnr)
  if not src then
    return
  end
  local list = store.for_key(src.root, src.key)
  if #list == 0 then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    return -- content not loaded yet
  end
  local opts = config.options

  for _, a in ipairs(list) do
    local found = anchor(bufnr, src.root, a)
    local t = opts.display
    local lnum = math.min(a.lnum, line_count)
    local end_lnum = math.min(math.max(a.end_lnum, lnum), line_count)
    local start_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local end_line = vim.api.nvim_buf_get_lines(bufnr, end_lnum - 1, end_lnum, false)[1] or ""

    local mark = { sign_text = t.sign and t.icon or nil, sign_hl_group = t.hl, priority = 150 }
    if found then
      mark.hl_group = t.range_hl
      if a.linewise then
        mark.end_row, mark.end_col, mark.hl_eol = end_lnum - 1, #end_line, true
      else
        mark.end_row, mark.end_col = end_lnum - 1, math.min(a.end_col, #end_line)
      end
    end
    local col = (found and not a.linewise) and math.min(a.col, #start_line) or 0
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, col, mark)
    if ok and found then
      tracked[bufnr][a.id] = id
    end

    if opts.display.box then
      local label = found and opts.label or (opts.label .. " · text not found")
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, end_lnum - 1, 0, {
        virt_lines = box(a.text, label, indent_of(start_line), t.hl),
      })
    end
  end
end

---Copy the positions of the extmarks (which follow edits) back to the store,
---with the text they now cover.
---@param bufnr integer
function M.sync(bufnr)
  local marks = tracked[bufnr]
  if not marks or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local src = source.resolve(bufnr)
  if not src then
    return
  end
  local changed = false
  for _, a in ipairs(store.for_key(src.root, src.key)) do
    local id = marks[a.id]
    if id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, id, { details = true })
      if pos and pos[1] and pos[3] and pos[3].end_row then
        local moved = {
          linewise = a.linewise,
          lnum = pos[1] + 1,
          col = pos[2],
          end_lnum = pos[3].end_row + 1,
          end_col = pos[3].end_col,
        }
        local text = M.text_at(bufnr, moved)
        if text ~= "" and (moved.lnum ~= a.lnum or moved.col ~= a.col or moved.end_lnum ~= a.end_lnum
          or (not a.linewise and moved.end_col ~= a.end_col) or text ~= a.code) then
          a.lnum, a.col, a.end_lnum, a.code = moved.lnum, moved.col, moved.end_lnum, text
          if not a.linewise then
            a.end_col = moved.end_col
          end
          changed = true
        end
      end
    end
  end
  if changed then
    store.save(src.root)
  end
end

function M.sync_all()
  for bufnr in pairs(tracked) do
    M.sync(bufnr)
  end
end

function M.render_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.render(bufnr)
    end
  end
end

---Annotation under the cursor: the smallest one whose range contains it.
---@return Annotation|nil, AnnotateSource|nil, string|nil reason
function M.at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local src, reason = source.resolve(bufnr)
  if not src then
    return nil, nil, reason
  end
  M.sync(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1], cur[2]
  local best, best_size
  for _, a in ipairs(store.for_key(src.root, src.key)) do
    if row >= a.lnum and row <= a.end_lnum then
      local inside = a.linewise
        or ((row > a.lnum or col >= a.col) and (row < a.end_lnum or col < a.end_col))
      -- On the right line but outside the columns still counts, ranked last.
      local size = (a.end_lnum - a.lnum) * 100000 + (a.linewise and 50000 or (a.end_col - a.col))
      if not inside then
        size = size + 1000000
      end
      if not best_size or size < best_size then
        best, best_size = a, size
      end
    end
  end
  if not best then
    return nil, src, "no annotation under the cursor"
  end
  return best, src
end

return M
