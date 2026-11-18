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
popup.open = function(type_id, _, cb)
  local ans = table.remove(answers, 1)
  cb(ans.type or type_id, ans.text)
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
  vim.cmd("'<,'>Annotate add issue")
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
  vim.cmd("'<,'>Annotate add question")
  vim.fn.cursor(7, 1)
  table.insert(answers, { text = "Nice." })
  annotate.add("praise")
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
  eq({ range[3], range[4].end_row, range[4].end_col, range[4].hl_group }, { 11, 3, 36, "DiagnosticVirtualTextError" })
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
  vim.cmd("'<,'>Annotate add note")
  vim.fn.cursor(4, 12)
  vim.cmd("normal! v\27")
  table.insert(answers, { text = "just r" })
  vim.cmd("'<,'>Annotate add issue")
  eq(#store.all(repo), 2)
  -- cursor on `r`: the smaller (inner) annotation wins
  vim.fn.cursor(4, 12)
  table.insert(answers, { text = "edited", type = "suggestion" })
  annotate.edit()
  local by_text = {}
  for _, a in ipairs(store.all(repo)) do
    by_text[a.text] = a
  end
  assert(by_text.edited and by_text.edited.type == "suggestion", "inner one edited")
  annotate.delete()
  eq(#store.all(repo), 1)
  eq(store.all(repo)[1].text, "whole tail")
end)

test("types are replaced, not merged", function()
  annotate.setup({ data_dir = tmp .. "/data", types = { { id = "todo" }, { id = "bug", label = "BUG!" } } })
  local ids = vim.tbl_map(function(t)
    return t.id
  end, require("annotate.config").options.types)
  eq(ids, { "todo", "bug" })
  eq(require("annotate.config").type("todo").label, "TODO")
  -- an annotation of a removed type still exports
  local text = annotate.build()
  assert(text:find("* NOTE #1:", 1, true), "removed type still exported")
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
  vim.cmd("'<,'>Annotate add question")
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

print(string.format("\n%d passed, %d failed", passed, failures))
vim.cmd(failures == 0 and "qa!" or "cq!")
