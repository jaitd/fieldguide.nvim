-- What the agent subprocess is told about this editor.
--
-- Shared by the terminal sidebar and the panel so the two cannot drift, and so
-- that removing either takes nothing with it.

local cfg = require("fieldguide.config")

local M = {}

---@return string the plugin's own root on disk
function M.plugin_root()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
end

---Where the plugin index lives, whether or not anything is there yet.
---@return string
function M.index_path()
  local p = cfg.paths()
  return vim.fn.expand(cfg.options.index.path or (p.state_dir .. "/nvim-plugins.db"))
end

---Where the plugin index is, if this machine has one. Absence is ordinary and
---not worth a warning: the tools it backs are optional.
---@return string
function M.plugin_index()
  local path = M.index_path()
  if vim.uv.fs_stat(path) then
    return path
  end
  return ""
end

---@return table<string, string>
function M.agent()
  local p = cfg.paths()
  local api = require("fieldguide.api")
  return {
    FIELDGUIDE_PLUGIN_INDEX = M.plugin_index(),
    -- Handed over explicitly rather than through $NVIM, so a future loosening
    -- of the tool list cannot silently re-expose the socket.
    FIELDGUIDE_ADDR = vim.v.servername,
    NVIM = "",
    FIELDGUIDE_BIN = M.plugin_root() .. "/bin/fieldguide",
    FIELDGUIDE_NVIM = p.nvim_bin or "nvim",
    FIELDGUIDE_CONFIG_DIR = p.config_dir,
    FIELDGUIDE_DOC_ROOTS = table.concat(p.doc_roots, ":"),
    FIELDGUIDE_VERBS = table.concat(api.verbs(), ","),
    FIELDGUIDE_RELOAD_LEVEL = cfg.options.reload.level,
  }
end

return M
