-- The config the containerised bridge tests answer from. Deliberately small,
-- and deliberately *real*: lazy.nvim with plugins at pinned revisions, because
-- `docs` and `state` are only meaningful against something actually installed.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- Both ship `doc/`, which is what makes them worth having here.
  { "folke/which-key.nvim", event = "VeryLazy", opts = {} },
  { "nvim-lua/plenary.nvim", lazy = false },
}, {
  checker = { enabled = false },
  change_detection = { enabled = false },
})

-- bridge.sh picks the first normal-mode mapping carrying a description and
-- asks `explain_keymap` to account for it. Give it one that is ours, so the
-- test does not depend on a plugin's own defaults.
vim.keymap.set("n", "<leader>fx", "<cmd>echo 'fixture'<cr>", { desc = "Fixture mapping" })
