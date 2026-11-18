local M = {}

---@class AnnotateType
---@field id string      stored identifier, e.g. "issue"
---@field label string   shown in the box and in the export, e.g. "ISSUE"
---@field icon string    sign column icon
---@field hl string      highlight for the sign and the box
---@field range_hl string highlight for the annotated text

---@class AnnotateConfig
M.defaults = {
  -- Ordered list. Setting `types` in setup() REPLACES this list: leave out a
  -- type to remove it, change the order to change the picker order.
  types = {
    { id = "issue", label = "ISSUE", icon = "!", hl = "DiagnosticError", range_hl = "DiagnosticVirtualTextError" },
    { id = "question", label = "QUESTION", icon = "?", hl = "DiagnosticWarn", range_hl = "DiagnosticVirtualTextWarn" },
    { id = "suggestion", label = "SUGGESTION", icon = "*", hl = "DiagnosticHint", range_hl = "DiagnosticVirtualTextHint" },
    { id = "note", label = "NOTE", icon = "i", hl = "DiagnosticInfo", range_hl = "DiagnosticVirtualTextInfo" },
    { id = "praise", label = "PRAISE", icon = "+", hl = "DiagnosticOk", range_hl = "DiagnosticVirtualTextOk" },
  },

  display = {
    box = true, -- comment box below the annotated text
    sign = true,
  },

  popup = {
    width = 70,
    height = 6,
    border = "rounded",
    submit = "<C-s>", -- insert and normal mode
    cancel = "q", -- normal mode
    cycle_type = "<Tab>", -- normal mode
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

  -- Extra resolvers: function(bufnr) -> { root, path, url?, base_url? } | nil
  -- Tried before the built-in ones. See README.
  resolvers = {},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  local types = opts.types
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if types then
    merged.types = vim.deepcopy(types) -- replace, never merge
  end
  for _, t in ipairs(merged.types) do
    assert(type(t.id) == "string", "annotate: every type needs an id")
    t.label = t.label or t.id:upper()
    t.icon = t.icon or "●"
    t.hl = t.hl or "Comment"
    t.range_hl = t.range_hl or "Visual"
  end
  M.options = merged
end

---@param id string
---@return AnnotateType|nil
function M.type(id)
  for _, t in ipairs(M.options.types) do
    if t.id == id then
      return t
    end
  end
end

return M
