-- pi as the agent: the default, and the one the panel starts without a
-- sandbox or an MCP server, since its extension talks to the editor itself.
-- Its command line is rpc.argv's; what is here is what the wizard and the
-- terminal sidebar both need to ask first.

local cfg = require("fieldguide.config")

local M = {}

M.name = "pi"

M.MIN_VERSION = { 0, 79, 0 }

---Launch-time problems, said before a process is spawned: no pi, or one too
---old for the extension. A version that cannot be read is let through, since
---refusing on a cosmetic check would be worse than the error pi gives itself.
---@param _ table? the launch options; pi's command comes from setup()
---@return string? error
function M.preflight(_)
  local cmd = cfg.options.cmd or "pi"
  if vim.fn.executable(cmd) == 0 then
    return ("%q is not on PATH. Install pi with:\n  npm install -g @earendil-works/pi-coding-agent"):format(cmd)
  end
  local ok, res = pcall(function()
    return vim.system({ cmd, "--version" }, { text = true }):wait(5000)
  end)
  if not ok then
    return nil
  end
  -- First line only: some tools print a banner, and the whole thing ends up in
  -- the failure message otherwise.
  local version = vim.trim(vim.split(res.stdout or "", "\n")[1] or "")
  local major, minor, patch = version:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    return nil
  end
  local have = { tonumber(major), tonumber(minor), tonumber(patch) }
  for i = 1, 3 do
    if have[i] > M.MIN_VERSION[i] then
      return nil
    end
    if have[i] < M.MIN_VERSION[i] then
      return ("pi %s is older than the minimum %d.%d.%d. Update with:\n  pi update self"):format(
        version,
        M.MIN_VERSION[1],
        M.MIN_VERSION[2],
        M.MIN_VERSION[3]
      )
    end
  end
  return nil
end

---pi's models, as `pi --list-models` lists them: only providers it has a
---login or key for, each with the provider it belongs to, so a pick from
---here is a pair pi accepts together.
---@return { provider: string, model: string }[]
function M.models()
  local cmd = cfg.options.cmd or "pi"
  if vim.fn.executable(cmd) == 0 then
    return {}
  end
  local ok, r = pcall(function()
    return vim.system({ cmd, "--list-models" }, { text = true }):wait(20000)
  end)
  if not ok or r.code ~= 0 then
    return {}
  end
  -- Rows only after the table's header: anything else pi prints, "No models
  -- available." among it, is prose, and its first two words are no pair.
  local out, header = {}, false
  for line in vim.gsplit(r.stdout or "", "\n", { plain = true }) do
    if not header then
      header = line:match("^provider%s+model%f[%s]") ~= nil
    else
      local provider, model = line:match("^(%S+)%s+(%S+)")
      if provider then
        table.insert(out, { provider = provider, model = model })
      end
    end
  end
  return out
end

return M
