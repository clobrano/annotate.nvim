-- Turns the current selection (or the cursor line) into a range.
local M = {}

---@class AnnotateRange
---@field lnum integer
---@field col integer
---@field end_lnum integer
---@field end_col integer
---@field linewise boolean

---Byte just past the character that starts at byte `col1` (1-based) of `line`.
local function char_end(line, col1)
  if col1 > #line then
    return #line
  end
  local ch = vim.fn.strcharpart(line:sub(col1), 0, 1)
  return col1 - 1 + math.max(#ch, 1)
end

local function line_at(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
end

---@param bufnr integer
---@param s integer[] getpos() result for the start
---@param e integer[] getpos() result for the end
---@param mode string "v", "V" or "\22"
---@return AnnotateRange
local function build(bufnr, s, e, mode)
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  if mode == "V" then
    return { lnum = s[2], col = 0, end_lnum = e[2], end_col = 0, linewise = true }
  end
  if mode == "\22" then
    -- Block selections become the character range between the two corners.
    local c1, c2 = math.min(s[3], e[3]), math.max(s[3], e[3])
    s, e = { 0, s[2], c1 }, { 0, e[2], c2 }
  end
  local end_line = line_at(bufnr, e[2])
  local r = {
    lnum = s[2],
    col = math.min(s[3] - 1, #line_at(bufnr, s[2])),
    end_lnum = e[2],
    end_col = char_end(end_line, e[3]),
    linewise = false,
  }
  if r.lnum == r.end_lnum and r.end_col <= r.col then
    return { lnum = r.lnum, col = 0, end_lnum = r.lnum, end_col = 0, linewise = true }
  end
  return r
end

---@param cmd_range? {line1: integer, line2: integer, range: integer} from a user command
---@return AnnotateRange
function M.get(cmd_range)
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()

  -- Called from a visual-mode mapping: the selection is still active.
  if mode == "v" or mode == "V" or mode == "\22" then
    local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return build(bufnr, s, e, mode)
  end

  -- Called as :'<,'>Annotate: use the last visual selection if it matches.
  if cmd_range and cmd_range.range > 0 then
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if s[2] == cmd_range.line1 and e[2] == cmd_range.line2 then
      return build(bufnr, s, e, vim.fn.visualmode())
    end
    return { lnum = cmd_range.line1, col = 0, end_lnum = cmd_range.line2, end_col = 0, linewise = true }
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return { lnum = lnum, col = 0, end_lnum = lnum, end_col = 0, linewise = true }
end

return M
