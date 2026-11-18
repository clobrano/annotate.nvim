-- Turns annotations into markdown for an agent and delivers it.
local M = {}

local config = require("annotate.config")

---Where the agent finds the annotated text.
---@param a Annotation
---@return string
function M.source(a)
  if a.url then
    local anchor = "#L" .. a.lnum
    if a.end_lnum ~= a.lnum then
      anchor = anchor .. "-L" .. a.end_lnum
    end
    return a.url .. anchor
  end
  if a.linewise then
    if a.end_lnum ~= a.lnum then
      return string.format("%s:%d-%d", a.path, a.lnum, a.end_lnum)
    end
    return string.format("%s:%d", a.path, a.lnum)
  end
  -- 1-based columns, end inclusive
  return string.format("%s:%d:%d-%d:%d", a.path, a.lnum, a.col + 1, a.end_lnum, a.end_col)
end

local function fence_for(code)
  local longest = 2
  for run in code:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return string.rep("`", longest + 1)
end

---The fence tag, but only for filetypes Neovim actually knows. A made-up
---filetype (e.g. one a plugin set on a captured tmux pane) is noise.
local known_filetypes ---@type table<string,true>?
local function fence_lang(lang)
  if not lang or lang == "" then
    return
  end
  if not known_filetypes then
    known_filetypes = {}
    for _, ft in ipairs(vim.fn.getcompletion("", "filetype")) do
      known_filetypes[ft] = true
    end
  end
  return known_filetypes[lang] and lang or nil
end

---Remove the indentation shared by all non-empty lines.
local function dedent(lines)
  local min
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^%s*")
      min = min and math.min(min, n) or n
    end
  end
  if not min or min == 0 then
    return lines
  end
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:sub(min + 1)
  end
  return out
end

---Default format:
---
---    * NOTE #1:
---      > ```go
---      > code
---      > ```
---      > source: path:12:5-12:30
---
---      The comment.
---@param a Annotation
---@param i integer
---@return string
function M.format(a, i)
  local indent = "  "
  local out = { string.format("* %s #%d:", config.options.label, i) }

  local code = vim.split(a.code or "", "\n", { plain = true })
  if a.linewise then
    code = dedent(code)
  else
    -- The first line starts at the selection; align the others to it.
    local rest = dedent(vim.list_slice(code, 2))
    code = { code[1], unpack(rest) }
  end
  local fence = fence_for(a.code or "")
  local function quote(s)
    table.insert(out, s == "" and (indent .. ">") or (indent .. "> " .. s))
  end
  quote(fence .. (fence_lang(a.lang) or ""))
  for _, l in ipairs(code) do
    quote(l)
  end
  quote(fence)
  quote("source: " .. M.source(a))

  table.insert(out, "")
  for _, l in ipairs(vim.split(a.text, "\n", { plain = true })) do
    table.insert(out, l == "" and "" or (indent .. l))
  end
  return table.concat(out, "\n")
end

---@param list Annotation[]
---@return string
function M.build(list)
  list = vim.list_slice(list)
  table.sort(list, function(x, y)
    if x.path ~= y.path then
      return x.path < y.path
    end
    if x.lnum ~= y.lnum then
      return x.lnum < y.lnum
    end
    return (x.col or 0) < (y.col or 0)
  end)
  local opts = config.options.export
  local fmt = opts.format or M.format
  local parts = {}
  if opts.header then
    table.insert(parts, (opts.header:gsub("%%d", tostring(#list))))
  end
  for i, a in ipairs(list) do
    table.insert(parts, fmt(a, i))
  end
  return table.concat(parts, "\n\n") .. "\n"
end

-- Delivery ------------------------------------------------------------------

local function run(cmd, input)
  local out = vim.fn.system(cmd, input)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(out)
  end
  return out
end

M.targets = {}

---@param text string
---@param done fun(ok: boolean, msg: string)
function M.targets.clipboard(text, _, done)
  local reg = config.options.export.register
  if (reg == "+" or reg == "*") and vim.fn.has("clipboard") == 0 then
    reg = '"'
  end
  vim.fn.setreg(reg, text)
  done(true, string.format("copied to register %s", reg))
end

function M.targets.file(text, root, done)
  local path = config.options.export.file
  if not path:match("^/") then
    path = root .. "/" .. path
  end
  local f, err = io.open(path, "w")
  if not f then
    return done(false, err)
  end
  f:write(text)
  f:close()
  done(true, "written to " .. vim.fn.fnamemodify(path, ":~:."))
end

local function tmux_send(text, target, done)
  local _, err = run({ "tmux", "load-buffer", "-b", "annotate", "-" }, text)
  if err then
    return done(false, err)
  end
  -- -p: bracketed paste, so agent CLIs take the whole export as one input
  _, err = run({ "tmux", "paste-buffer", "-p", "-d", "-b", "annotate", "-t", target })
  if err then
    return done(false, err)
  end
  if config.options.tmux.submit then
    run({ "tmux", "send-keys", "-t", target, "Enter" })
  end
  done(true, "pasted into tmux pane " .. target)
end

---Split `tmux list-panes` output into display strings and a map back to pane
---ids. Strings, not tables, so any vim.ui.select implementation shows them
---readably (some pickers ignore format_item).
---@param out string
---@return string[] entries, table<string,string> pane_of
function M._pane_entries(out)
  local entries = {}
  local pane_of = {}
  for line in out:gmatch("[^\n]+") do
    local p = vim.split(line, "\t", { plain = true })
    if p[1] ~= vim.env.TMUX_PANE then
      local display = string.format("%s  %s  %s  %s", p[2], p[3], p[4], p[5])
      table.insert(entries, display)
      pane_of[display] = p[1]
    end
  end
  return entries, pane_of
end

function M.targets.tmux(text, _, done)
  if vim.env.TMUX == nil or vim.env.TMUX == "" then
    return done(false, "not inside tmux")
  end
  local target = config.options.tmux.target
  if target then
    return tmux_send(text, target, done)
  end
  local out, err = run({
    "tmux", "list-panes", "-s", "-F",
    "#{pane_id}\t#{window_index}.#{pane_index}\t#{window_name}\t#{pane_current_command}\t#{pane_title}",
  })
  if not out then
    return done(false, err)
  end
  local entries, pane_of = M._pane_entries(out)
  if #entries == 0 then
    return done(false, "no other tmux pane in this session")
  end
  vim.ui.select(entries, {
    prompt = "Send annotations to pane",
  }, function(display)
    if not display then
      return done(false, "cancelled")
    end
    tmux_send(text, pane_of[display], done)
  end)
end

return M
