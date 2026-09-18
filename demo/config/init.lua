-- The config the demo recording answers from. Deliberately small, and
-- deliberately *real*: the whole claim is that fieldguide answers from plugins
-- that are actually installed, so a stub config would demo nothing.
--
-- Not your config. record.sh points XDG_CONFIG_HOME here, so the recording
-- shows this tree and not your home directory, your plugins or your paths.
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

-- The demo runs the working tree, which is the point: what it shows is what the
-- branch does. record.sh copies this file into the throwaway profile and says
-- where the checkout is; the fallback is this file's own place in it.
local repo = vim.env.FIELDGUIDE_DEMO_REPO or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

vim.g.mapleader = " "

require("lazy").setup({
  -- Plugins with a `doc/` directory and keymaps of their own: between them the
  -- questions in demo.tape have real help text to resolve and a real mapping to
  -- attribute.
  { "folke/which-key.nvim", event = "VeryLazy", opts = {} },
  { "lewis6991/gitsigns.nvim", event = "VeryLazy", opts = {} },
  { "nvim-lua/plenary.nvim", lazy = false },
  {
    "jaitd/fieldguide.nvim",
    name = "fieldguide.nvim",
    dir = repo,
    lazy = false,
    opts = {
      -- Left to pi's own settings: whoever records this uses the provider they
      -- are logged in to, and no key belongs in a committed file.
      provider = vim.env.FIELDGUIDE_DEMO_PROVIDER,
      model = vim.env.FIELDGUIDE_DEMO_MODEL,
      window = { side = "right", width = 72 },
      -- The recording edits nothing, and a prompt mid-take would stall it.
      reload = { level = "manual" },
      keys = { toggle = "<leader>fg" },
    },
  },
}, {
  checker = { enabled = false },
  change_detection = { enabled = false },
  install = { colorscheme = { "habamax" } },
})

vim.o.number = true
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.cmd.colorscheme("habamax")
