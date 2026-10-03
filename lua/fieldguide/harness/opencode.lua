-- opencode as fieldguide's agent, over ACP (`opencode acp`).
--
-- The profile is three layers, and each one assumes the one before it failed:
--
--   1. opencode's own config: no shell, no network, no subagents, no skills;
--      writes allowed, directories outside the config and doc zones denied.
--   2. The plugin (extension/harness/opencode-plugin.ts): the three-zone gate
--      from gate.ts on every tool call, refusing any tool it does not know,
--      and pi's checkpoint-and-verify around every write.
--   3. The agent sandbox, when there is one: `needs()` says what opencode must
--      still be able to reach inside it.
--
-- What opencode would otherwise pull in unasked is switched off by environment:
-- a project's opencode.json and AGENTS.md from the config tree and every
-- directory above it, and the user's Claude Code skills and CLAUDE.md. The
-- user's *global* opencode config is still merged in — it is where their
-- providers are defined — so a tool or MCP server declared there can appear;
-- the plugin refuses every tool it does not name, which is what makes that
-- safe rather than merely unlikely.

local cfg = require("fieldguide.config")

local M = {}

M.name = "opencode"
M.protocol = "acp"

---@return string
local function home()
  return vim.uv.os_homedir() or ""
end

---@param var string
---@param fallback string
---@return string
local function xdg(var, fallback)
  local value = vim.env[var]
  return (value and value ~= "") and value or (home() .. "/" .. fallback)
end

---@param p string?
---@return string?
local function real(p)
  return p and p ~= "" and vim.uv.fs_realpath(p) or nil
end

---The node the plugin runs mcp.ts on, and the relay runs as: `o.node`, or
---PATH's. Resolved, because a version manager's `node/24` is a link to
---`node/24.x.y`, and inside the agent sandbox only the target is bound.
---@param o fieldguide.HarnessOpts
---@return string?
local function node_bin(o)
  local node = o.node or vim.fn.exepath("node")
  if node == "" then
    return nil
  end
  return real(node) or node
end

---The MCP server opencode is given in ACP's `session/new`. With
---`o.mcp_socket`, the server runs outside the agent sandbox (`mcp.ts
-----listen`, started by the editor) and opencode gets the relay: stdio to that
---socket and nothing else, needing none of the editor's variables. Without
---one, `o.mcp` is the server itself.
---@param o fieldguide.HarnessOpts
---@return table { command, args, env }
function M.mcp(o)
  if o.mcp_socket then
    return {
      command = node_bin(o) or "node",
      args = { o.root .. "/extension/mcp.ts", "--relay", o.mcp_socket },
      env = {},
    }
  end
  return o.mcp
end

---Where fieldguide keeps what it generates for opencode, and opencode's own
---record of fieldguide's sessions.
---@return string
function M.state_dir()
  return cfg.paths().state_dir .. "/harness/opencode"
end

---opencode's own $HOME, empty, inside `state_dir()`.
---@return string
function M.home()
  local dir = M.state_dir() .. "/home"
  vim.fn.mkdir(dir, "p")
  return dir
end

---The config opencode runs with. Pure, so the policy can be read and tested
---without starting anything.
---@param o fieldguide.HarnessOpts
---@return table
function M.config(o)
  local external = { ["*"] = "deny" }
  for _, root in ipairs(o.doc_roots or {}) do
    external[root] = "allow"
    external[root .. "/**"] = "allow"
  end

  local config = {
    ["$schema"] = "https://opencode.ai/config.json",
    plugin = { "file://" .. o.root .. "/extension/harness/opencode-plugin.ts" },
    instructions = { o.system_prompt },
    -- Off at the source, so the model is never offered them. The plugin
    -- refuses them again if a later opencode adds one under a new name.
    tools = {
      bash = false,
      webfetch = false,
      websearch = false,
      codesearch = false,
      task = false,
      skill = false,
    },
    permission = {
      bash = "deny",
      webfetch = "deny",
      -- Asking would put a dialog in front of every edit the gate already
      -- vetted; see `acp.GRANTED_KINDS` for why fieldguide does not ask.
      edit = "allow",
      -- opencode's own path check, a second opinion on the plugin's. The
      -- config tree is the working directory, so it is never external.
      external_directory = external,
    },
    -- Both run programs from the config tree on their own schedule: a
    -- formatter after each edit, a language server on each read. Neither goes
    -- through the gate.
    formatter = false,
    lsp = false,
    share = "disabled",
    autoupdate = false,
  }
  if o.model then
    config.model = o.model
  end
  return config
end

---Written where the file's name is its content's hash: two editors with
---different configs cannot overwrite each other's, and an unchanged config
---is not rewritten.
---@param o fieldguide.HarnessOpts
---@return string path
function M.write_config(o)
  local dir = M.state_dir()
  vim.fn.mkdir(dir, "p")
  local text = vim.json.encode(M.config(o))
  local path = ("%s/config-%s.json"):format(dir, vim.fn.sha256(text):sub(1, 16))
  if not vim.uv.fs_stat(path) then
    local tmp = path .. ".tmp" .. vim.uv.os_getpid()
    vim.fn.writefile({ text }, tmp)
    vim.uv.fs_rename(tmp, path)
  end
  return path
end

---Inherited variables that would change what the agent is, rather than where
---it finds things. `OPENCODE_PURE` drops the plugin — the gate with it — and
---`OPENCODE_CONFIG_CONTENT` and `OPENCODE_PERMISSION` are merged over the
---config above; a parent Claude Code's own variables tell a child it is inside
---one.
---@param name string
---@return boolean
local function inherited_hazard(name)
  return name:match("^OPENCODE_") ~= nil or name == "CLAUDECODE" or name:match("^CLAUDE_CODE_") ~= nil
end

---@param set table<string, string> what `env()` sets, which is not inherited
---@return string[] sorted
function M.hazards(set)
  local out = {}
  for name in pairs(vim.fn.environ()) do
    if set[name] == nil and inherited_hazard(name) then
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

---@param o fieldguide.HarnessOpts
---@return string[]
function M.argv(o)
  -- Unset, not blanked: the process environment is the editor's with ours
  -- merged over it, and a merge cannot delete. opencode rejects an empty
  -- value for its boolean flags outright, so `env -u` it is.
  local argv = {}
  local hazards = M.hazards(M.env(o))
  if #hazards > 0 then
    argv = { "env" }
    for _, name in ipairs(hazards) do
      vim.list_extend(argv, { "-u", name })
    end
  end
  -- The session's directory and MCP server travel in ACP's `session/new`,
  -- not on the command line. By its real path: the name on PATH is often a
  -- link outside every zone the agent sandbox binds.
  return vim.list_extend(argv, { real(vim.fn.exepath("opencode")) or "opencode", "acp" })
end

---@param o fieldguide.HarnessOpts
---@return table<string, string>
function M.env(o)
  local env = {
    OPENCODE_CONFIG = M.write_config(o),
    -- Sessions in a database of fieldguide's own: out of the user's opencode
    -- history, and theirs out of this panel's. A private XDG_DATA_HOME would
    -- do the same, but only by copying the credentials into it, and a token
    -- refreshed into the copy is one the real file never learns about.
    OPENCODE_DB = M.state_dir() .. "/opencode.db",
    -- The recent-model list and prompt history opencode keeps for its own UI.
    -- A fieldguide session has no business reordering either.
    XDG_STATE_HOME = M.state_dir() .. "/state",
    -- A project opencode.json or AGENTS.md in the config tree, or in any
    -- directory above it, would otherwise be merged into the agent's config
    -- and prompt.
    OPENCODE_DISABLE_PROJECT_CONFIG = "1",
    -- ~/.claude/CLAUDE.md and ~/.claude/skills are read by default. opencode
    -- 1.x honours these two; v2 no longer reads either, which is why $HOME
    -- below is opencode's own.
    OPENCODE_DISABLE_CLAUDE_CODE = "1",
    OPENCODE_DISABLE_EXTERNAL_SKILLS = "1",
    OPENCODE_DISABLE_AUTOUPDATE = "1",
  }
  -- opencode finds ~/.claude (CLAUDE.md, skills) and ~/.agents (skills)
  -- through $HOME, so it gets an empty one of its own: there is nothing there
  -- to merge into the agent's prompt, whichever opencode it is. Inside the
  -- macOS sandbox it is also what keeps it starting at all, because a
  -- refused ~/.claude is EPERM rather than missing, and v2 fails the session
  -- on it. Its own directories are named outright so the move takes none of
  -- them along: the credentials, the user's providers, the ripgrep in its
  -- cache. A provider whose credentials live elsewhere under $HOME (~/.aws,
  -- say) is the cost.
  env.HOME = M.home()
  env.XDG_CONFIG_HOME = xdg("XDG_CONFIG_HOME", ".config")
  env.XDG_DATA_HOME = xdg("XDG_DATA_HOME", ".local/share")
  env.XDG_CACHE_HOME = xdg("XDG_CACHE_HOME", ".cache")
  -- The plugin's write hooks run mcp.ts on this node, which the sandbox binds.
  env.FIELDGUIDE_NODE = node_bin(o)
  if o.mcp_socket then
    -- The write hooks ask the server on this socket rather than the editor,
    -- and nothing in opencode's process tree is handed the editor's address.
    env.FIELDGUIDE_MCP_SOCKET = o.mcp_socket
    env.FIELDGUIDE_ADDR = ""
  end
  return env
end

---What opencode itself must reach inside the agent sandbox.
---
---The data directory is writable because the credentials live there and are
---refreshed in place; the cache holds the ripgrep that grep and glob run.
---@param o fieldguide.HarnessOpts? the launch options, for the node they name
---@return { ro: string[], rw: string[] }
function M.needs(o)
  local ro = {
    require("fieldguide.env").plugin_root(),
    -- Where the user's providers are defined.
    xdg("XDG_CONFIG_HOME", ".config") .. "/opencode",
  }
  local bin = vim.fn.exepath("opencode")
  if bin ~= "" then
    table.insert(ro, vim.fn.fnamemodify(vim.uv.fs_realpath(bin) or bin, ":h"))
  end
  -- The node the write hooks and the relay run on; unbound, neither starts,
  -- and the plugin refuses every write for want of a checkpoint.
  local node = node_bin(o or {})
  if node then
    table.insert(ro, vim.fs.dirname(vim.fs.dirname(node)))
  end
  return {
    ro = ro,
    rw = {
      xdg("XDG_DATA_HOME", ".local/share") .. "/opencode",
      xdg("XDG_CACHE_HOME", ".cache") .. "/opencode",
      M.state_dir(),
    },
  }
end

return M
