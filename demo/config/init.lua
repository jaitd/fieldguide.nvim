-- Neovim, with a handful of plugins managed by lazy.nvim.

vim.o.background = "dark"
vim.g.mapleader = " "

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
  { "folke/which-key.nvim", event = "VeryLazy", opts = {} },
  { "nvim-lua/plenary.nvim", lazy = false },
  {
    "lewis6991/gitsigns.nvim",
    event = "VeryLazy",
    opts = {},
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
  {
    "jaitd/fieldguide.nvim",
    name = "fieldguide.nvim",
    lazy = false,
    opts = {
      provider = "openai-codex",
      model = "gpt-5.6-luna",
      window = { side = "right", width = 72 },
      -- Edits apply; reloading the config still asks first.
      reload = { level = "verify-only" },
      keys = { toggle = "<leader>fg" },
      chat = { user_name = "you" },
    },
    config = function(_, opts)
      require("fieldguide").setup(opts)
    end,
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
