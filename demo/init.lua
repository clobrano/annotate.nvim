-- Minimal config for the VHS demo: `vhs demo/demo.tape` from the repo root.
local repo = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.runtimepath:prepend(repo)

vim.g.mapleader = " "
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true
vim.opt.swapfile = false
vim.opt.hlsearch = false -- keep search matches from lingering in the recording
vim.opt.shortmess:append("I")
vim.opt.laststatus = 3

require("annotate").setup({
  -- Throwaway store, so the demo never touches real annotations.
  data_dir = vim.fn.tempname(),
})

local a = require("annotate")
vim.keymap.set({ "n", "x" }, "<leader>aa", a.add, { desc = "Annotate" })
vim.keymap.set("n", "<leader>ap", a.preview, { desc = "Annotate: preview" })
vim.keymap.set("n", "]a", function() a.jump(1) end, { desc = "Next annotation" })
vim.keymap.set("n", "[a", function() a.jump(-1) end, { desc = "Previous annotation" })
