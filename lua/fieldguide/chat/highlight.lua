-- Highlight groups for the transcript.
--
-- A transcript mixes three kinds of line — what you asked, what the agent said,
-- and what it did — and only the first two are prose. Tool calls are machinery:
-- worth being able to find, not worth reading unless something went wrong. So
-- they are dimmed to the colour of a comment and anchored by a small coloured
-- glyph, which leaves the agent's own answer as the only thing on the page in
-- the foreground colour.
--
-- Every group is defined with `default = true` and linked rather than styled, so
-- a colourscheme that knows about fieldguide wins, and one that does not still
-- gets something coherent.

local M = {}

M.links = {
  FieldguideTitle = "Title", -- the panel's own name, in the transcript winbar
  FieldguideSession = "Comment", -- the session marker the transcript opens with
  FieldguideUser = "Identifier", -- whose turn it is, above your own messages
  FieldguidePlaceholder = "NonText", -- the prompt's empty-state hint
  FieldguideTool = "Comment", -- the summary text of a tool call
  FieldguideToolDetail = "Comment", -- its expanded body
  FieldguideToolIcon = "Function", -- the glyph a tool line starts with
  FieldguideToolOk = "DiagnosticOk",
  FieldguideToolError = "DiagnosticError",
  -- Added/Removed rather than DiffAdd/DiffDelete: those are background fills
  -- meant for a diff window, and a fold inside a transcript is not one.
  -- The marker beside a command the agent wrote, and offers to load for you.
  FieldguideRun = "Special",
  -- The bar down the side of the message you are reading.
  FieldguideCurrent = "CursorLineNr",
  FieldguideDiffAdd = "Added",
  FieldguideDiffDelete = "Removed",
}

local applied = false

function M.apply()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

---Idempotent. A `:colorscheme` clears the highlight table, so the links have to
---be re-established afterwards or the transcript loses its colour mid-session.
function M.setup()
  M.apply()
  if applied then
    return
  end
  applied = true
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("fieldguide.chat.highlight", { clear = true }),
    callback = M.apply,
  })
end

return M
