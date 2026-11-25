-- nvim --headless -u NONE -l tests/run.lua   (or: nvim --headless -u NONE -c "luafile tests/run.lua")
local root_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root_dir)
vim.cmd("runtime plugin/annotate.lua")

local failures, passed = 0, 0
local function test(name, fn)
  require("annotate.store")._reset()
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(string.format("%s\nexpected: %s\n     got: %s", msg or "", vim.inspect(b), vim.inspect(a)), 2)
  end
end

-- Fixture: a git repo with a Go file, and a private data dir.
local tmp = vim.fn.tempname()
local repo = tmp .. "/repo"
vim.fn.mkdir(repo .. "/pkg", "p")
vim.fn.mkdir(repo .. "/.git", "p")
local go = {
  "package pkg",
  "",
  "func Reconcile(ctx context.Context) error {",
  "\tif err := r.Client.Update(ctx, obj); err != nil {",
  "\t\treturn err",
  "\t}",
  "\treturn nil",
  "}",
}
vim.fn.writefile(go, repo .. "/pkg/reconcile.go")
repo = vim.loop.fs_realpath(repo)

local annotate = require("annotate")
local popup = require("annotate.popup")
local store = require("annotate.store")
local export = require("annotate.export")

annotate.setup({ data_dir = tmp .. "/data", export = { register = "a" } })

-- Popup stub: answer with the next queued text.
local answers = {}
popup.open = function(_, cb)
  cb(table.remove(answers, 1).text)
end

local function open_go()
  vim.cmd("silent! %bwipeout!")
  vim.fn.writefile(go, repo .. "/pkg/reconcile.go")
  store._reset()
  vim.cmd("edit " .. repo .. "/pkg/reconcile.go")
  vim.bo.filetype = "go"
  vim.wait(20)
end

test("charwise selection from :'<,'>Annotate", function()
  vim.fn.delete(tmp .. "/data", "rf")
  open_go()
  -- select `r.Client.Update(ctx, obj)` on line 4
  vim.fn.cursor(4, 12)
  vim.cmd("normal! vf)\27")
  table.insert(answers, { text = "Should be a Patch." })
  vim.cmd("'<,'>Annotate add")
  local list = store.all(repo)
  eq(#list, 1)
  local a = list[1]
  eq(a.code, "r.Client.Update(ctx, obj)")
  eq({ a.lnum, a.col, a.end_lnum, a.end_col, a.linewise }, { 4, 11, 4, 36, false })
  eq(a.path, "pkg/reconcile.go")
  eq(export.source(a), "pkg/reconcile.go:4:12-4:36")
end)

test("visual-mode mapping keeps the character range", function()
  open_go()
  local got
  vim.keymap.set("x", "Q", function()
    got = require("annotate.selection").get()
  end)
  vim.fn.cursor(5, 1)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("^vwQ", true, false, true), "x", false)
  eq(got, { lnum = 5, col = 2, end_lnum = 5, end_col = 10, linewise = false })
  eq(vim.fn.mode(), "n", "visual mode exited")
end)

test("linewise selection and cursor line", function()
  open_go()
  vim.fn.cursor(5, 1)
  vim.cmd("normal! Vj\27")
  table.insert(answers, { text = "Why return here?" })
  vim.cmd("'<,'>Annotate add")
  vim.fn.cursor(7, 1)
  table.insert(answers, { text = "Nice." })
  annotate.add()
  local list = store.all(repo)
  eq(#list, 3)
  eq(list[2].code, "\t\treturn err\n\t}")
  eq(export.source(list[2]), "pkg/reconcile.go:5-6")
  eq(export.source(list[3]), "pkg/reconcile.go:7")
end)

test("export format", function()
  local text = annotate.build()
  local expected = table.concat({
    "## Annotations (3)",
    "",
    "* NOTE #1:",
    "  > ```go",
    "  > r.Client.Update(ctx, obj)",
    "  > ```",
    "  > source: pkg/reconcile.go:4:12-4:36",
    "",
    "  Should be a Patch.",
    "",
    "* NOTE #2:",
    "  > ```go",
    "  > \treturn err",
    "  > }",
    "  > ```",
    "  > source: pkg/reconcile.go:5-6",
    "",
    "  Why return here?",
    "",
    "* NOTE #3:",
    "  > ```go",
    "  > return nil",
    "  > ```",
    "  > source: pkg/reconcile.go:7",
    "",
    "  Nice.",
    "",
  }, "\n")
  eq(text, expected)
  annotate.export("clipboard")
  eq(vim.fn.getreg("a"), expected)
end)

test("renders range highlight, sign and box", function()
  open_go()
  local ns = require("annotate.render").ns
  local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
  local range
  for _, m in ipairs(marks) do
    if m[2] == 3 and m[4].end_row then
      range = m
    end
  end
  assert(range, "range mark on line 4")
  eq({ range[3], range[4].end_row, range[4].end_col, range[4].hl_group }, { 11, 3, 36, "DiagnosticVirtualTextInfo" })
  local boxes = vim.tbl_filter(function(m)
    return m[4].virt_lines ~= nil
  end, marks)
  eq(#boxes, 3)
end)

test("annotations follow edits and are saved on write", function()
  open_go()
  vim.api.nvim_buf_set_lines(0, 1, 1, false, { "// added", "// lines" })
  vim.cmd("silent write")
  local a = store.all(repo)[1]
  eq({ a.lnum, a.col, a.end_col }, { 6, 11, 36 })
  -- a fresh session reads the moved position from disk
  store._reset()
  eq(store.all(repo)[1].lnum, 6)
end)

test("text found again after the file changed on disk", function()
  vim.cmd("silent! %bwipeout!")
  local changed = vim.list_extend({ "package pkg", "", "// new comment", "// another" }, vim.list_slice(go, 3))
  vim.fn.writefile(changed, repo .. "/pkg/reconcile.go")
  store._reset()
  -- stored position is line 6 from the previous test; text is now on line 6? make it differ:
  local a = store.all(repo)[1]
  a.lnum, a.end_lnum = 2, 2
  store.save(repo)
  vim.cmd("edit " .. repo .. "/pkg/reconcile.go")
  require("annotate.render").render(0)
  eq({ a.lnum, a.col }, { 6, 11 })
end)

test("missing text is flagged, not moved", function()
  vim.cmd("silent! %bwipeout!")
  vim.fn.writefile({ "package pkg", "", "func X() {}", "", "", "", "", "" }, repo .. "/pkg/reconcile.go")
  store._reset()
  vim.cmd("edit " .. repo .. "/pkg/reconcile.go")
  require("annotate.render").render(0)
  local a = store.all(repo)[1]
  eq(a.lnum, 6)
  local marks = vim.api.nvim_buf_get_extmarks(0, require("annotate.render").ns, 0, -1, { details = true })
  local found_label = false
  for _, m in ipairs(marks) do
    if m[4].virt_lines and m[4].virt_lines[1][1][1]:find("text not found", 1, true) then
      found_label = true
    end
  end
  assert(found_label, "box says the text was not found")
end)

test("edit and delete at the cursor", function()
  open_go()
  store._reset()
  vim.fn.delete(tmp .. "/data", "rf")
  vim.fn.cursor(4, 1)
  vim.cmd("normal! fiv$\27")
  table.insert(answers, { text = "whole tail" })
  vim.cmd("'<,'>Annotate add")
  vim.fn.cursor(4, 12)
  vim.cmd("normal! v\27")
  table.insert(answers, { text = "just r" })
  vim.cmd("'<,'>Annotate add")
  eq(#store.all(repo), 2)
  -- cursor on `r`: the smaller (inner) annotation wins
  vim.fn.cursor(4, 12)
  table.insert(answers, { text = "edited" })
  annotate.edit()
  local by_text = {}
  for _, a in ipairs(store.all(repo)) do
    by_text[a.text] = a
  end
  assert(by_text.edited and by_text["whole tail"], "inner one edited")
  annotate.delete()
  eq(#store.all(repo), 1)
  eq(store.all(repo)[1].text, "whole tail")
end)

test("label setting", function()
  annotate.setup({ data_dir = tmp .. "/data", label = "TODO", export = { header = false } })
  eq(annotate.build():match("^[^\n]*"), "* TODO #1:")
  annotate.setup({ data_dir = tmp .. "/data", export = { register = "a" } })
end)

test("custom format function", function()
  annotate.setup({ data_dir = tmp .. "/data", export = { header = false, format = function(a, i)
    return i .. ":" .. a.text
  end } })
  eq(annotate.build(), "1:whole tail\n")
  annotate.setup({ data_dir = tmp .. "/data", export = { register = "a" } })
end)

test("gh-review buffers get a commit link", function()
  package.loaded["gh_review.state"] = {
    get_merge_base_oid = function() return "base123" end,
    get_base_oid = function() return "base000" end,
    get_head_oid = function() return "head456" end,
    get_owner = function() return "org" end,
    get_name = function() return "repo" end,
    get_host = function() return "github.com" end,
  }
  vim.cmd("cd " .. repo)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_name(buf, "gh-review://RIGHT/api/v1/types.go")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "package v1", "", "type Spec struct {", "\tTimeout *Duration", "}" })
  vim.fn.cursor(4, 10)
  vim.cmd("normal! v$\27")
  table.insert(answers, { text = "Default?" })
  vim.cmd("'<,'>Annotate add")
  local remote
  for _, a in ipairs(store.all(repo)) do
    if a.url then
      remote = a
    end
  end
  assert(remote, "stored under the repo root")
  eq(remote.key, "api/v1/types.go@head456")
  eq(export.source(remote), "https://github.com/org/repo/blob/head456/api/v1/types.go#L4")
  eq(remote.code, "*Duration")
  -- the LEFT side is a different key, at the merge base
  local left = require("annotate.source").resolve(vim.api.nvim_create_buf(false, true))
  eq(left, nil)
end)

test("clear archives everything", function()
  vim.cmd("edit " .. repo .. "/pkg/reconcile.go")
  annotate.clear()
  eq(#store.all(repo), 0)
  eq(#vim.fn.glob(tmp .. "/data/archive/*.json", false, true), 1)
end)

test("helpful reason for buffers it can't annotate", function()
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  local src, reason = require("annotate.source").resolve(0)
  eq(src, nil)
  eq(reason, "not a file buffer (buftype=nofile)")
end)

test("made-up filetypes get no fence tag", function()
  open_go()
  vim.bo.filetype = "tmuxreview"
  vim.fn.cursor(7, 1)
  table.insert(answers, { text = "no tag" })
  annotate.add()
  local text = annotate.build()
  assert(
    text:find("\n  > ```\n  > return nil\n  > ```\n", 1, true),
    "plain fence, no tag:\n" .. text
  )
end)

test("buffer-scoped export, preview and archive", function()
  -- start from an empty project store and a clean archive dir
  vim.fn.delete(tmp .. "/data/archive", "rf")
  vim.cmd("edit " .. repo .. "/pkg/reconcile.go")
  vim.bo.filetype = "go"
  annotate.clear()
  -- one annotation in each of two files
  vim.fn.cursor(4, 12)
  table.insert(answers, { text = "in main" })
  annotate.add()
  vim.fn.writefile({ "package pkg", "", "func Other() {}" }, repo .. "/pkg/other.go")
  vim.cmd("edit " .. repo .. "/pkg/other.go")
  vim.bo.filetype = "go"
  vim.fn.cursor(3, 1)
  table.insert(answers, { text = "in other" })
  annotate.add()
  -- scoped to other.go: only its note
  local text = annotate.build("buffer")
  assert(text:find("in other", 1, true), text)
  assert(not text:find("in main", 1, true), text)
  eq(text:match("^## Annotations %((%d+)%)"), "1")
  -- unscoped: both
  text = annotate.build()
  assert(text:find("in main", 1, true) and text:find("in other", 1, true), text)
  -- scoped preview shows only the current buffer
  annotate.preview("buffer")
  local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(lines:find("in other", 1, true) and not lines:find("in main", 1, true), lines)
  vim.cmd("close")
  -- scoped export with clear_after_export archives only this buffer's note
  annotate.setup({ data_dir = tmp .. "/data", export = { register = "a", clear_after_export = true } })
  annotate.export("clipboard", "buffer")
  local left = store.all(repo)
  eq(#left, 1)
  eq(left[1].text, "in main")
  local archived = vim.json.decode(table.concat(vim.fn.readfile(
    vim.fn.glob(tmp .. "/data/archive/*.json", false, true)[1]
  ), "\n"))
  eq(#archived.annotations, 1)
  eq(archived.annotations[1].text, "in other")
  annotate.setup({ data_dir = tmp .. "/data", export = { register = "a" } })
end)

test(":Annotate! export scopes to the buffer", function()
  vim.cmd("edit " .. repo .. "/pkg/other.go")
  vim.fn.cursor(3, 1)
  table.insert(answers, { text = "bang note" })
  annotate.add()
  vim.cmd("Annotate! export")
  local text = vim.fn.getreg("a")
  assert(text:find("bang note", 1, true), text)
  assert(not text:find("in main", 1, true), text)
end)

test("tmux pane picker offers strings, not tables", function()
  vim.env.TMUX_PANE = "%0"
  local entries, pane_of = export._pane_entries(
    "%0\t1.0\tmain\tnvim\teditor\n" ..
    "%21\t1.1\tagents\tclaude\tagent pane\n"
  )
  vim.env.TMUX_PANE = nil
  eq(entries, { "1.1  agents  claude  agent pane" })
  eq(pane_of["1.1  agents  claude  agent pane"], "%21")
end)

test("tmux export asks for a configured pane, with the count", function()
  local orig_confirm = export._confirm
  annotate.setup({ data_dir = tmp .. "/data", export = { register = "a" }, tmux = { target = "%5" } })
  vim.env.TMUX = "/tmp/sock,1,0"
  local asked
  export._confirm = function(msg)
    asked = msg
    return false
  end
  for _, case in ipairs({ { 3, "Send 3 annotations to pane %5?" }, { 1, "Send 1 annotation to pane %5?" } }) do
    local ok, msg
    export.targets.tmux("text", repo, function(o, m)
      ok, msg = o, m
    end, case[1])
    eq(asked, case[2])
    eq({ ok, msg }, { false, "cancelled" }, "cancel aborts before tmux runs")
  end
  export._confirm = orig_confirm
  vim.env.TMUX = nil
  annotate.setup({ data_dir = tmp .. "/data", export = { register = "a" } })
end)

test("box wraps long comments", function()
  open_go()
  vim.fn.cursor(7, 1) -- "}", no indent
  table.insert(answers, { text = string.rep("word ", 30) })
  annotate.add()
  local render_ns = require("annotate.render").ns
  local marks = vim.api.nvim_buf_get_extmarks(0, render_ns, 0, -1, { details = true })
  local box_lines
  for _, m in ipairs(marks) do
    if m[4].virt_lines then
      box_lines = m[4].virt_lines
    end
  end
  assert(box_lines, "box rendered")
  -- header + wrapped body + footer
  assert(#box_lines > 3, "expected several body lines, got " .. #box_lines)
  local words = {}
  for i = 2, #box_lines - 1 do
    local text = box_lines[i][1][1]
    local w = vim.fn.strdisplaywidth(text)
    assert(w <= 64, ("body line too wide (%d): %s"):format(w, text))
    -- strip borders: pad .. "│ " .. content .. " │"
    for word in (text:match("│ (.-) │$") or ""):gmatch("%S+") do
      table.insert(words, word)
    end
  end
  eq(#words, 30, "all words kept across wrapped lines")
end)

test("ephemeral filetypes are kept in memory only", function()
  vim.fn.delete(tmp .. "/data", "rf")
  open_go()
  vim.bo.filetype = "tmuxreview"
  vim.fn.cursor(7, 1)
  table.insert(answers, { text = "session note" })
  annotate.add()
  eq(#store.all(repo), 1)
  eq(store.is_ephemeral(repo), true)
  -- nothing written to disk
  eq(#vim.fn.glob(tmp .. "/data/*.json", false, true), 0)
  -- a fresh session starts empty: the disk file was never there
  store._reset()
  eq(#store.all(repo), 0)
  -- clear archives in memory only, no archive file either
  vim.bo.filetype = "tmuxreview"
  vim.fn.cursor(7, 1)
  table.insert(answers, { text = "again" })
  annotate.add()
  annotate.clear()
  eq(#store.all(repo), 0)
  eq(#vim.fn.glob(tmp .. "/data/archive/*.json", false, true), 0)
end)

print(string.format("\n%d passed, %d failed", passed, failures))
vim.cmd(failures == 0 and "qa!" or "cq!")
