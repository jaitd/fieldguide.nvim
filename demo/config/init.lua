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

-- Installed from GitHub like anyone else's, not from the checkout this file
-- sits in. Two reasons, and the second is the one that matters: a demo should
-- show what a user gets, and a local checkout is outside every zone the agent
-- may read, so the first question it answers is punctuated by the gate refusing
-- to open the plugin's own README. Installed, the plugin lives in the profile's
-- lazy directory, which *is* the read-only doc zone.
--
-- FIELDGUIDE_DEMO_LOCAL=1 records the working tree instead, for checking a
-- change before it is merged. Expect that refusal in the take.
local checkout = vim.env.FIELDGUIDE_DEMO_REPO

vim.g.mapleader = " "

require("lazy").setup({
  -- Plugins with a `doc/` directory and keymaps of their own: between them the
  -- questions in demo.tape have real help text to resolve and a real mapping to
  -- attribute.
  { "folke/which-key.nvim", event = "VeryLazy", opts = {} },
  {
    "lewis6991/gitsigns.nvim",
    event = "VeryLazy",
    opts = {},
    -- A keymap the plugin owns, for `explain_keymap` to attribute.
    keys = {
      {
        "<leader>gb",
        function()
          require("gitsigns").toggle_current_line_blame()
        end,
        desc = "Toggle Git blame",
      },
    },
  },
  { "nvim-lua/plenary.nvim", lazy = false },
  {
    "jaitd/fieldguide.nvim",
    name = "fieldguide.nvim",
    dir = checkout,
    lazy = false,
    opts = {
      -- The pair the recordings are made with, overridable for a take on
      -- another provider. Credentials are pi's business either way: they come
      -- from the environment or `pi auth`, never from a committed file.
      provider = vim.env.FIELDGUIDE_DEMO_PROVIDER or "openai-codex",
      model = vim.env.FIELDGUIDE_DEMO_MODEL or "gpt-5.6-luna",
      window = { side = "right", width = 72 },
      -- Whoever records this is not the point, and $USER would be on screen.
      chat = { user_name = "you" },
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
