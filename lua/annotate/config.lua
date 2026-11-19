local M = {}

---@class AnnotateConfig
M.defaults = {
  -- Shown on the box in Neovim and at the start of each exported item ("* NOTE #1:").
  label = "NOTE",

  display = {
    box = true, -- comment box below the annotated text
    sign = true,
    icon = "▍", -- sign column icon
    hl = "DiagnosticInfo", -- sign and box
    range_hl = "DiagnosticVirtualTextInfo", -- the annotated text
    wrap = 60, -- wrap the comment box text at this display width; false = never wrap
  },

  popup = {
    width = 70,
    height = 6,
    border = "rounded",
    submit = "<C-s>", -- insert and normal mode
    cancel = "q", -- normal mode
  },

  -- Where stores live (one JSON file per project root).
  data_dir = vim.fn.stdpath("data") .. "/annotate",

  export = {
    -- First line of the export, or false. "%d" is replaced with the count.
    header = "## Annotations (%d)",
    -- Custom formatter: function(annotation, index) -> string. nil uses the default.
    format = nil,
    -- Archive and clear the project's annotations after a successful export.
    clear_after_export = false,
    -- File target: path relative to the project root (or absolute).
    file = ".annotations.md",
    -- Clipboard register.
    register = "+",
  },

  tmux = {
    -- Target pane (tmux target syntax, e.g. "{last}", "agents:1.0"). nil = pick from a list.
    target = nil,
    -- Press Enter after pasting.
    submit = false,
  },

  -- Extra resolvers: function(bufnr) -> { root, key?, path, url? } | nil
  -- Tried before the built-in ones. See README.
  resolvers = {},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
