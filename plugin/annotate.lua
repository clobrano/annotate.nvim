if vim.g.loaded_annotate then
  return
end
vim.g.loaded_annotate = true

local subcommands = {
  add = function(_, range)
    require("annotate").add(range)
  end,
  edit = function()
    require("annotate").edit()
  end,
  delete = function()
    require("annotate").delete()
  end,
  list = function()
    require("annotate").list()
  end,
  export = function(args, _, bang)
    require("annotate").export(args[1], bang and "buffer" or nil)
  end,
  preview = function(_, _, bang)
    require("annotate").preview(bang and "buffer" or nil)
  end,
  clear = function()
    require("annotate").clear()
  end,
}

vim.api.nvim_create_user_command("Annotate", function(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1) or "add"
  local fn = subcommands[name]
  if not fn then
    return vim.notify("annotate: unknown subcommand " .. name, vim.log.levels.ERROR)
  end
  fn(args, { line1 = opts.line1, line2 = opts.line2, range = opts.range }, opts.bang)
end, {
  nargs = "*",
  range = true,
  bang = true,
  desc = "Annotate code for an AI agent",
  complete = function(_, line)
    local words = vim.split(line, "%s+")
    if #words <= 2 then
      return vim.tbl_keys(subcommands)
    end
    if words[2] == "export" then
      return { "clipboard", "file", "tmux" }
    end
    return {}
  end,
})

local group = vim.api.nvim_create_augroup("annotate", { clear = true })

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function(ev)
    -- Plugins like gh-review fill their buffers right after showing them.
    vim.schedule(function()
      require("annotate.render").render(ev.buf)
    end)
  end,
})

vim.api.nvim_create_autocmd({ "BufWritePost", "BufLeave" }, {
  group = group,
  callback = function(ev)
    require("annotate.render").sync(ev.buf)
  end,
})
