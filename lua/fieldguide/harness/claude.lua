-- Claude Code as the agent: how to launch it, and what it needs.
--
-- Claude runs natively over stream-json, one long-lived process per session,
-- and `fieldguide.rpc.claude` reads what it writes. No ACP adapter: that would
-- be an npm package fetched at runtime, and Claude's own hooks are what carry
-- the gate, which an adapter would have to be trusted to pass through.
--
-- The posture is pi's: our tools and nothing else. Every flag below closes a
-- door that is open by default —
--
--   --tools                  the built-ins, cut to the five file tools. No
--                            Bash, no WebFetch, no Task.
--   --strict-mcp-config      only our MCP server; none of the user's.
--   --setting-sources ""     none of the user's settings, hooks, permissions or
--                            CLAUDE.md files. --settings still applies, and
--                            that is where our hooks come from.
--   --disable-slash-commands no skills. A skill is a prompt from somewhere else.
--
-- `--bare` would say most of that in one flag, but it also skips hooks — the
-- gate — and refuses OAuth logins, so it is exactly the wrong one.

local M = {}

M.name = "claude"
M.protocol = "claude"

-- Only the tools the gate has a translation for. Anything added here needs a
-- row in extension/harness/claude-hook.ts first, or the hook denies it.
M.tools = { "Read", "Edit", "Write", "Grep", "Glob" }

---@param p string?
---@return string?
local function real(p)
  return p and p ~= "" and vim.uv.fs_realpath(p) or nil
end

---@param p string
---@return boolean
local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

-- Credentials that arrive in the environment rather than from a file Claude
-- keeps. With one of these Claude never touches .credentials.json at all (its
-- credential store goes "bare"), which is what makes a home of our own safe.
local TOKEN_VARS = { "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN" }

-- What a Claude Code session exports to the processes it starts. Inherited by
-- a nested claude, they make it believe it is a child of that session. Named
-- one by one rather than stripped by prefix: CLAUDE_CODE_OAUTH_TOKEN,
-- CLAUDE_CODE_USE_BEDROCK and friends are the user's own configuration.
M.inherited = {
  "CLAUDECODE",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_SESSION_ID",
  "CLAUDE_CODE_CHILD_SESSION",
  "CLAUDE_CODE_SESSION_ATTENDED",
  "CLAUDE_CODE_MESSAGING_SOCKET",
  "CLAUDE_CODE_MESSAGING_TOKEN",
  "CLAUDE_CODE_EXECPATH",
  "CLAUDE_PID",
  "CLAUDE_EFFORT",
}

---"token" when the credential is in the environment, "login" when it is the
---OAuth login Claude keeps in its own home.
---@return "token"|"login"
function M.auth()
  for _, name in ipairs(TOKEN_VARS) do
    local v = vim.env[name]
    if v and v ~= "" then
      return "token"
    end
  end
  return "login"
end

---Where Claude keeps its own state: sessions, credentials, the account file.
---
---With a token credential, a home of fieldguide's own, so its sessions stay
---out of the user's Claude history (Claude has no --session-dir; this is the
---only lever). With a login, the user's own home, and nothing copied out of
---it: Claude replaces .credentials.json by rename and rotates the refresh
---token when it refreshes, so a copy that refreshes signs the original out, and
---a bind of the single file cannot be renamed over.
---@return string
function M.claude_home()
  if M.auth() == "token" then
    return ("%s/fieldguide/claude-home"):format(vim.fn.stdpath("state"))
  end
  local dir = vim.env.CLAUDE_CONFIG_DIR
  if dir and dir ~= "" then
    return vim.fs.normalize(dir)
  end
  return vim.fs.normalize("~/.claude")
end

---One directory per editor process for the generated settings and MCP config.
---
---Per process rather than per launch, because every launch from one editor
---writes the same thing; and never in the user's config dir or in ~/.claude,
---because either would change what their own `claude` does there.
---@return string
function M.dir()
  return ("%s/fieldguide/harness/claude/%d"):format(vim.fn.stdpath("state"), vim.fn.getpid())
end

---Claude's temp dir for this editor's sessions, inside `M.dir()`.
---@return string
function M.tmpdir()
  local dir = M.dir() .. "/tmp"
  vim.fn.mkdir(dir, "p")
  return dir
end

---Directories left behind by editors that are no longer running.
local function prune(parent)
  for name, kind in vim.fs.dir(parent) do
    local pid = tonumber(name)
    if kind == "directory" and pid and pid ~= vim.fn.getpid() then
      -- kill(pid, 0) sends nothing; it only asks whether the process exists.
      local alive = vim.uv.kill(pid, 0) == 0
      if not alive then
        vim.fn.delete(parent .. "/" .. name, "rf")
      end
    end
  end
end

---@param o fieldguide.HarnessOpts
---@return string?
local function node_bin(o)
  -- The hook's interpreter, by absolute path. A hook command that fails to
  -- start is a non-blocking error to Claude — the tool runs ungated — so this
  -- is resolved here, where a missing node can stop the launch instead.
  -- Resolved, as the sandbox binds it: a version manager's `node/24` is a
  -- link to `node/24.x.y`, and inside an agent sandbox only the target exists.
  local node = o.node or vim.fn.exepath("node")
  if node == "" then
    return nil
  end
  return real(node) or node
end

---@param o fieldguide.HarnessOpts
---@return string
local function hook_path(o)
  return o.root .. "/extension/harness/claude-hook.ts"
end

---Launch-time problems, said before a process is spawned.
---@param o fieldguide.HarnessOpts
---@return string? error
function M.preflight(o)
  if vim.fn.executable("claude") == 0 then
    return '"claude" is not on PATH'
  end
  local node = node_bin(o)
  if not node then
    return "node is not on PATH, and Claude's hooks — the path gate — run on it"
  end
  -- A path is not proof. The hook itself is run, the way Claude will run it:
  -- a node that is missing, too old to strip TypeScript, or cannot resolve
  -- the hook's imports fails here, before any tool can run ungated.
  local ok, r = pcall(function()
    return vim.system({ node, hook_path(o), "check" }, { text = true }):wait(10000)
  end)
  if not ok or r.code ~= 0 or vim.trim(r.stdout or "") ~= "ok" then
    local why = not ok and tostring(r) or vim.trim((r.stderr ~= "" and r.stderr) or ("exit " .. tostring(r.code)))
    return ("%s cannot run Claude's hook — the path gate — so Claude is not started: %s"):format(node, why)
  end
  return nil
end

---@param o fieldguide.HarnessOpts
---@return table settings as Claude reads them
function M.settings(o)
  local node = vim.fn.shellescape(node_bin(o) or "node")
  local hook = vim.fn.shellescape(hook_path(o))

  -- Reads of the doc zone are outside cwd, where Claude would otherwise ask —
  -- and in -p mode, asking means refusing. `//` is Claude's spelling of an
  -- absolute path. Writes there are refused by the gate regardless.
  local allow = { "mcp__fieldguide" }
  for _, root in ipairs(o.doc_roots or {}) do
    for _, tool in ipairs({ "Read", "Grep", "Glob" }) do
      table.insert(allow, ("%s(/%s/**)"):format(tool, root))
    end
  end

  return {
    hooks = {
      PreToolUse = {
        {
          matcher = "*",
          -- A timed-out hook is a non-blocking error too. Generous, because the
          -- pre-write step checkpoints through the editor.
          -- `|| exit 2` makes any failure to run the gate a refusal: exit 2 is
          -- the one code Claude treats as blocking, and a node that cannot
          -- start, inside a sandbox preflight never saw, exits 126 or 127.
          hooks = { { type = "command", command = ("%s %s pre || exit 2"):format(node, hook), timeout = 60 } },
        },
      },
      PostToolUse = {
        {
          matcher = "Write|Edit|MultiEdit|NotebookEdit",
          hooks = { { type = "command", command = ("%s %s post"):format(node, hook), timeout = 120 } },
        },
      },
    },
    permissions = {
      -- Edits inside cwd — the config dir — without asking, which in -p mode
      -- would be refusing. The gate is the check, not a prompt nobody can see.
      defaultMode = "acceptEdits",
      allow = allow,
    },
  }
end

---@param o fieldguide.HarnessOpts
---@return table
function M.mcp_config(o)
  local mcp = o.mcp or {}
  return {
    mcpServers = {
      fieldguide = {
        type = "stdio",
        command = mcp.command,
        args = mcp.args or {},
        env = mcp.env or vim.empty_dict(),
      },
    },
  }
end

---@param path string
---@param value table
local function write_json(path, value)
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode(value))
  f:close()
end

---Writes the settings and MCP config it points at; each launch rewrites them.
---@param o fieldguide.HarnessOpts
---@return string[]
function M.argv(o)
  local dir = M.dir()
  vim.fn.mkdir(dir, "p")
  pcall(prune, vim.fs.dirname(dir))
  local settings, mcp = dir .. "/settings.json", dir .. "/mcp.json"
  write_json(settings, M.settings(o))
  write_json(mcp, M.mcp_config(o))

  local argv = {
    -- By its real path: the name on PATH is usually a symlink in ~/.local/bin,
    -- which an agent sandbox does not bind, and the versions directory it
    -- points into is what `needs()` does.
    real(vim.fn.exepath("claude")) or "claude",
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    -- stream-json output refuses to run without it.
    "--verbose",
    -- Token deltas. Without this the panel would get each message whole.
    "--include-partial-messages",
    -- The only way a PostToolUse hook's verify reaches the stream.
    "--include-hook-events",
    "--tools",
    table.concat(M.tools, ","),
    "--strict-mcp-config",
    "--mcp-config",
    mcp,
    "--setting-sources",
    "",
    "--settings",
    settings,
    "--disable-slash-commands",
    -- Without this the agent is a general coding assistant that happens to have
    -- our tools, and answers questions about this editor from training data.
    "--append-system-prompt-file",
    o.system_prompt,
  }
  if o.model then
    vim.list_extend(argv, { "--model", o.model })
  end
  if o.session then
    -- Claude's own session store, not fieldguide's: Claude has no
    -- --session-dir, so resuming is by id out of `claude_home()`/projects.
    vim.list_extend(argv, { "--resume", o.session })
  end
  return argv
end

---@param _ fieldguide.HarnessOpts
---@return table<string, string>
function M.env(_)
  local env = {
    -- An update swapping the binary out from under a running session, from a
    -- process the user did not start, is not ours to allow.
    DISABLE_AUTOUPDATER = "1",
  }
  -- Emptied rather than removed: vim.system merges this over the parent's
  -- environment and has no way to unset, and Claude reads each of these as a
  -- JavaScript truthiness test, which "" fails.
  for _, name in ipairs(M.inherited) do
    env[name] = ""
  end
  -- Claude's scratch space, which is otherwise /tmp/claude-<uid>: shared with
  -- every other Claude session of the user's, and not ours to put in reach.
  env.CLAUDE_CODE_TMPDIR = M.tmpdir()
  if M.auth() == "token" then
    local home = M.claude_home()
    vim.fn.mkdir(home, "p")
    env.CLAUDE_CONFIG_DIR = home
  end
  return env
end

---What Claude itself needs to be able to reach inside an agent sandbox.
---@return { ro: string[], rw: string[] }
function M.needs()
  local ro, rw = {}, {}
  local function add(list, p)
    if p and exists(p) and not vim.tbl_contains(list, p) then
      table.insert(list, p)
    end
  end

  -- The binary is a single file in a versions directory. The directory, read
  -- only: it is what an update would write, and updates are off.
  local bin = real(vim.fn.exepath("claude"))
  add(ro, bin and vim.fs.dirname(bin) or nil)
  local node = real(vim.fn.exepath("node"))
  add(ro, node and vim.fs.dirname(vim.fs.dirname(node)) or nil)
  -- Created here too: the sandbox is planned before or after argv() writes
  -- into it, and a zone that does not exist yet would be dropped.
  vim.fn.mkdir(M.dir(), "p")
  add(ro, M.dir())

  -- Writable, not because the agent writes there but because Claude does:
  -- sessions and file history under its home, and — with a login — the OAuth
  -- token it refreshes. Always the directory, never the file: Claude replaces
  -- .credentials.json by rename, which a single-file bind refuses.
  local home = M.claude_home()
  if M.auth() == "token" then
    vim.fn.mkdir(home, "p")
  end
  add(rw, home)
  if M.auth() == "login" and (not vim.env.CLAUDE_CONFIG_DIR or vim.env.CLAUDE_CONFIG_DIR == "") then
    -- The one file outside the home. Bound as a file because $HOME cannot be;
    -- if Claude ever replaces it by rename too, that write fails inside the
    -- sandbox and the session carries on without it.
    add(rw, vim.fs.normalize("~/.claude.json"))
  end
  if M.auth() == "login" and vim.uv.os_uname().sysname == "Darwin" then
    -- On macOS a login lives in the Keychain, which Claude's process opens
    -- itself: without the keychain files it reports "Not logged in". Read
    -- only. Anything else in there is still behind the Keychain's own
    -- per-item access control.
    add(ro, vim.fs.normalize("~/Library/Keychains"))
  end
  add(rw, M.tmpdir())
  add(rw, vim.fs.normalize("~/.cache/claude"))
  add(rw, vim.fs.normalize("~/.local/state/claude"))
  return { ro = ro, rw = rw }
end

return M
