-- The doctor's editor: the user's own config, loaded as usual so its
-- fieldguide options (a `cmd`, a `cwd`) are what gets checked, then this
-- checkout's fieldguide in place of whichever one the config installed.
-- Prepended after the config has run, because lazy.nvim resets the
-- runtimepath while it loads.
local installed = package.loaded["fieldguide.config"]
local opts = installed and vim.deepcopy(installed.options) or {}
for name in pairs(package.loaded) do
  if name == "fieldguide" or name:match("^fieldguide%.") then
    package.loaded[name] = nil
  end
end
vim.opt.runtimepath:prepend(vim.env.FIELDGUIDE_DOCTOR_ROOT)
require("fieldguide.config").setup(opts)
