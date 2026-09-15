-- A lazy.nvim spec naming a plugin that is not on disk. Under read-only mounts
-- and --unshare-net this must be *reported*, never installed.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({ { "fieldguide/definitely-not-installed" } })
