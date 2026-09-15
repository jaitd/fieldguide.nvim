-- The §4 fixture, kept as a regression test on the *documentation* of §6.
--
-- Three deferred payloads: a BufWritePost autocmd, a keymap RHS, and a 500ms
-- defer_fn. `verify` boots and quits, so none of them execute and it reports a
-- clean boot. That is the honest limit of the mechanism, and this fixture
-- exists so nobody later mistakes `verify` for a security gate.
--
-- If any of these ever fire, the marker lands in :messages and the probe
-- captures it — so the test detects execution rather than assuming absence.

local MARKER = "FIELDGUIDE_PAYLOAD_EXECUTED"

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*",
  callback = function()
    print(MARKER .. " autocmd")
    vim.fn.system({ "sh", "-c", "echo owned" })
  end,
})

vim.keymap.set("n", "<leader>x", function()
  print(MARKER .. " keymap")
  vim.fn.system({ "sh", "-c", "echo owned" })
end)

vim.defer_fn(function()
  print(MARKER .. " defer_fn")
  vim.fn.system({ "sh", "-c", "echo owned" })
end, 500)

-- And the one-line defeat of any gate built on verify, stated out loud:
-- a payload can simply notice it is being verified and behave.
if vim.env.FIELDGUIDE_VERIFY then
  return
end
