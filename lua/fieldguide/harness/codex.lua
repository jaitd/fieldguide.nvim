-- Codex as the agent: how to launch it, and what it needs.
--
-- Codex runs as `codex exec --json`, one process per prompt, and a later
-- prompt resumes the thread by id (`codex exec resume`). fieldguide.rpc.codex
-- reads what it writes.
--
-- Codex has no file tools but `apply_patch`: it reads, and can write, through
-- its shell, and a hook sees a shell call only as a command string. So there
-- is no path gate for reads to be had from hooks, and the agent sandbox is
-- the read gate. `preflight` refuses to launch without one. Inside it Codex's
-- own sandbox is off (`danger-full-access`): macOS refuses to nest one seatbelt
-- in another, and every shell command would fail. Ours is the boundary.
--
-- The posture is pi's, as far as Codex can be told it:
--
--   --ignore-user-config, --ignore-rules   none of the user's config.toml or
--                                          execpolicy rules
--   a CODEX_HOME of our own                none of the user's global AGENTS.md,
--                                          skills, memories or sessions; only
--                                          the login is shared
--   project_doc_max_bytes = 0              no AGENTS.md from the config tree
--   web_search = "disabled"                no web
--   hooks (extension/harness/codex-hook.ts) the gate on apply_patch, and
--                                          checkpoint and verify around writes,
--                                          the shell's included, and at the end
--                                          of each turn
--   --dangerously-bypass-hook-trust        Codex otherwise runs no hook a person
--                                          has not reviewed; fieldguide writes
--                                          these itself

local cfg = require("fieldguide.config")

local M = {}

M.name = "codex"
M.protocol = "codex"
-- Read by whatever launches a harness: Codex is only ever started inside
-- `fieldguide.sandbox.agent_plan`.
M.requires_sandbox = true

-- The first Codex this profile was checked against: hooks stable, --json
-- items, --ignore-user-config, and the flags above.
M.MIN_VERSION = { 0, 160 }

-- Codex's native packages, by `uname`. The npm package is a node script that
-- finds one of these and runs it.
local PLATFORMS = {
  ["Darwin arm64"] = { triple = "aarch64-apple-darwin", pkg = "codex-darwin-arm64" },
  ["Darwin x86_64"] = { triple = "x86_64-apple-darwin", pkg = "codex-darwin-x64" },
  ["Linux x86_64"] = { triple = "x86_64-unknown-linux-musl", pkg = "codex-linux-x64" },
  ["Linux aarch64"] = { triple = "aarch64-unknown-linux-musl", pkg = "codex-linux-arm64" },
}

-- What a Codex session exports to the processes it starts. Inherited, they
-- would tell this Codex it is running inside another one.
M.inherited = { "CODEX_THREAD_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_MANAGED_BY_NPM" }

---@param p string?
---@return string?
local function real(p)
  return p and p ~= "" and vim.uv.fs_realpath(p) or nil
end

---An executable rather than a script: ELF or Mach-O, by magic number.
---@param p string
---@return boolean
local function is_native(p)
  local f = io.open(p, "rb")
  if not f then
    return false
  end
  local magic = f:read(4) or ""
  f:close()
  return magic == "\127ELF"
    or magic == "\207\250\237\254"
    or magic == "\206\250\237\254"
    or magic == "\202\254\186\190"
    or magic == "\254\237\250\207"
end

---The @openai/codex package a launcher on PATH belongs to: `bin/codex.js`
---itself, or the shell wrapper pnpm writes, which names it.
---@param launcher string
---@return string?
local function package_of(launcher)
  if launcher:match("/bin/codex%.js$") then
    return vim.fs.dirname(vim.fs.dirname(launcher))
  end
  local f = io.open(launcher, "r")
  if not f then
    return nil
  end
  local text = f:read(8192) or ""
  f:close()
  local rel = text:match('"%$basedir/([^"]-@openai/codex/bin/codex%.js)"')
  if not rel then
    return nil
  end
  local js = real(vim.fs.dirname(launcher) .. "/" .. rel)
  return js and vim.fs.dirname(vim.fs.dirname(js)) or nil
end

---The native Codex binary: `o.codex`, or what `codex` on PATH runs. By its
---real path, because the agent sandbox binds the install, not the launcher.
---@param o fieldguide.HarnessOpts?
---@return string?
function M.binary(o)
  local start = (o and o.codex) or vim.fn.exepath("codex")
  local bin = real(start)
  if not bin then
    return nil
  end
  if is_native(bin) then
    return bin
  end
  local pkg = package_of(bin)
  local uname = vim.uv.os_uname()
  local plat = PLATFORMS[uname.sysname .. " " .. uname.machine]
  if not pkg or not plat then
    return nil
  end
  for _, root in ipairs({
    vim.fs.dirname(pkg) .. "/" .. plat.pkg, -- hoisted or pnpm: a sibling
    pkg .. "/node_modules/@openai/" .. plat.pkg, -- npm: nested
    pkg, -- a package that bundles its own vendor/
  }) do
    local candidate = real(("%s/vendor/%s/bin/codex"):format(root, plat.triple))
    if candidate and is_native(candidate) then
      return candidate
    end
  end
  return nil
end

---The directory to bind for a binary: its package when it came from npm
---(`<pkg>/vendor/<triple>/bin/codex`, with rg and the code-mode host beside
---it), or the binary's own directory otherwise.
---@param bin string
---@return string
local function install_root(bin)
  local pkg = bin:match("^(.*)/vendor/[^/]+/bin/codex$")
  return pkg or vim.fs.dirname(bin)
end

---@param bin string
---@return integer[]? version
local function version_of(bin)
  local r = vim.system({ bin, "--version" }, { text = true }):wait(10000)
  local major, minor, patch = ((r.stdout or "") .. (r.stderr or "")):match("(%d+)%.(%d+)%.(%d+)")
  return major and { tonumber(major), tonumber(minor), tonumber(patch) } or nil
end

---@param o fieldguide.HarnessOpts
---@return string?
local function node_bin(o)
  local node = o.node or vim.fn.exepath("node")
  if node == "" then
    return nil
  end
  return real(node) or node
end

---@param o fieldguide.HarnessOpts
---@return string
local function hook_path(o)
  return o.root .. "/extension/harness/codex-hook.ts"
end

---Where fieldguide keeps what it generates for Codex.
---@return string
function M.state_dir()
  return cfg.paths().state_dir .. "/harness/codex"
end

---The user's own Codex home, where the login lives.
---@return string
local function user_home()
  local dir = vim.env.CODEX_HOME
  if dir and dir ~= "" then
    return vim.fs.normalize(dir)
  end
  return vim.fs.normalize("~/.codex")
end

---The CODEX_HOME Codex runs with: one of fieldguide's own, holding nothing
---but a link to the user's auth.json, so the user's global AGENTS.md, skills,
---memories and sessions are not there to be read, and the login is not a
---copy. Codex writes auth.json in place, through the link, so a refreshed
---token lands in the user's file.
---@return string home, string? login the user's auth.json, when there is one
function M.codex_home()
  local home = M.state_dir() .. "/home"
  vim.fn.mkdir(home, "p")
  local login = user_home() .. "/auth.json"
  if not vim.uv.fs_stat(login) then
    return home, nil
  end
  local link = home .. "/auth.json"
  if vim.uv.fs_readlink(link) ~= login then
    vim.uv.fs_unlink(link)
    vim.uv.fs_symlink(login, link)
  end
  return home, login
end

---Codex's own $HOME, empty. Codex walks ~/.agents/skills, and runs commands
---in a login shell that reads ~/.zshrc or ~/.bash_profile: here there are
---none of the user's, and nothing in the sandbox's log about the refusal.
---@return string
function M.shell_home()
  local dir = M.state_dir() .. "/shell-home"
  vim.fn.mkdir(dir, "p")
  return dir
end

---Launch-time problems, said before a process is spawned.
---@param o fieldguide.HarnessOpts
---@return string? error
function M.preflight(o)
  -- Codex reads through its shell, which no hook can path-check. Without the
  -- sandbox the whole disk would be readable, so there is no Codex without it.
  local which, err = require("fieldguide.sandbox").backend(
    o.sandbox,
    "agent.sandbox",
    "Codex reads files through its shell, so fieldguide runs it only sandboxed"
  )
  if not which then
    return err
  end
  -- Inside the sandbox the editor's socket is out of reach; the MCP server's
  -- is the only way to the tools.
  if not o.mcp_socket then
    return "Codex runs sandboxed, and needs the MCP server's socket (mcp_socket) to reach the tools"
  end
  -- A login in the system keyring is keyed by the Codex home's path, so it
  -- would need the user's own home in the sandbox: their sessions, memories
  -- and global instructions, readable to a shell with the network.
  if not select(2, M.codex_home()) then
    return ("Codex has no %s/auth.json: fieldguide needs a file login, not the system keyring. "):format(user_home())
      .. 'Set cli_auth_credentials_store = "file" in its config.toml and run `codex login`.'
  end
  local bin = M.binary(o)
  if not bin then
    return '"codex" is not on PATH, or its native binary could not be found behind it'
  end
  local v = version_of(bin)
  if not v then
    return ("cannot tell which Codex %s is"):format(bin)
  end
  if v[1] < M.MIN_VERSION[1] or (v[1] == M.MIN_VERSION[1] and v[2] < M.MIN_VERSION[2]) then
    return ("this is Codex %d.%d.%d; fieldguide needs %d.%d or later"):format(
      v[1],
      v[2],
      v[3],
      M.MIN_VERSION[1],
      M.MIN_VERSION[2]
    )
  end
  local node = node_bin(o)
  if not node then
    return "node is not on PATH, and Codex's hooks (the gate on apply_patch) run on it"
  end
  local ok, r = pcall(function()
    return vim.system({ node, hook_path(o), "check" }, { text = true }):wait(10000)
  end)
  if not ok or r.code ~= 0 or vim.trim(r.stdout or "") ~= "ok" then
    local why = not ok and tostring(r) or vim.trim((r.stderr ~= "" and r.stderr) or ("exit " .. tostring(r.code)))
    return ("%s cannot run Codex's hook, so Codex is not started: %s"):format(node, why)
  end
  return nil
end

---A string as TOML reads one: what `-c key=value` parses the value as.
---@param s string
---@return string
function M.toml_string(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    local named = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return named[c] or ("\\u%04x"):format(c:byte())
  end)
  return '"' .. escaped .. '"'
end

---@param path string
---@return string
local function read_file(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

---The argv for one prompt, which comes on stdin. `o.session` resumes a thread.
---@param o fieldguide.HarnessOpts
---@return string[]
function M.argv(o)
  local q = M.toml_string
  local node = node_bin(o) or "node"
  local function hook(mode, timeout)
    -- `|| exit 2`: a hook that cannot start blocks rather than lets through.
    -- Timeouts outlast the hook's own waits on the server (80s and 140s).
    local cmd = ("%s %s %s || exit 2"):format(vim.fn.shellescape(node), vim.fn.shellescape(hook_path(o)), mode)
    return ('[{matcher=".*",hooks=[{type="command",command=%s,timeout=%d}]}]'):format(q(cmd), timeout)
  end

  -- A hook that reports rather than gates: no matcher, and no `|| exit 2`.
  local function report(mode)
    local cmd = ("%s %s %s"):format(vim.fn.shellescape(node), vim.fn.shellescape(hook_path(o)), mode)
    return ('[{hooks=[{type="command",command=%s,timeout=150}]}]'):format(q(cmd))
  end

  local argv = { M.binary(o) or "codex", "exec" }
  if o.session then
    table.insert(argv, "resume")
  end
  vim.list_extend(argv, {
    "--json",
    "--ignore-user-config",
    "--ignore-rules",
    "--skip-git-repo-check",
    "--dangerously-bypass-hook-trust",
    "-c",
    'sandbox_mode="danger-full-access"',
    "-c",
    'approval_policy="never"',
    "-c",
    'web_search="disabled"',
    "-c",
    "project_doc_max_bytes=0",
    "-c",
    "developer_instructions=" .. q(read_file(o.system_prompt)),
    "-c",
    "hooks.PreToolUse=" .. hook("pre", 90),
    "-c",
    "hooks.PostToolUse=" .. hook("post", 150),
    -- The end of the turn, for a write a backgrounded command made after the
    -- last hook looked. No `|| exit 2` here: to a Stop hook, 2 means "keep
    -- going", and a check that failed must not keep the agent running.
    "-c",
    "hooks.Stop=" .. report("stop"),
    -- And at the start of the next prompt, for a change the end of the last
    -- turn let pass. Not `|| exit 2` either: that would drop the prompt.
    "-c",
    "hooks.UserPromptSubmit=" .. report("prompt"),
    "-c",
    "mcp_servers.fieldguide.command=" .. q(node),
    "-c",
    ("mcp_servers.fieldguide.args=[%s,%s,%s]"):format(
      q(o.root .. "/extension/mcp.ts"),
      q("--relay"),
      q(o.mcp_socket or "")
    ),
  })
  if o.model then
    vim.list_extend(argv, { "-m", o.model })
  end
  if o.session then
    table.insert(argv, o.session)
  end
  -- The prompt, from stdin: no length limit, and nothing of it in `ps`.
  table.insert(argv, "-")
  return argv
end

---@param o fieldguide.HarnessOpts
---@return table<string, string>
function M.env(o)
  local env = {
    CODEX_HOME = (M.codex_home()),
    HOME = M.shell_home(),
  }
  -- Emptied, not removed: the environment is merged over the editor's.
  for _, name in ipairs(M.inherited) do
    env[name] = ""
  end
  if o.mcp_socket then
    -- The write hooks ask the server on this socket rather than the editor,
    -- and nothing in Codex's process tree is handed the editor's address.
    env.FIELDGUIDE_MCP_SOCKET = o.mcp_socket
    env.FIELDGUIDE_ADDR = ""
  end
  return env
end

---What Codex itself must reach inside the agent sandbox.
---@param o fieldguide.HarnessOpts?
---@return { ro: string[], rw: string[] }
function M.needs(o)
  o = o or {}
  local ro, rw = {}, {}
  local function add(list, p)
    if p and vim.uv.fs_stat(p) and not vim.tbl_contains(list, p) then
      table.insert(list, p)
    end
  end
  local bin = M.binary(o)
  add(ro, bin and install_root(bin) or nil)
  -- The node the hooks and the relay run on; unbound, neither starts, and the
  -- gate refuses every patch for want of a checkpoint.
  local node = node_bin(o)
  add(ro, node and vim.fs.dirname(vim.fs.dirname(node)) or nil)

  local home, login = M.codex_home()
  -- Sessions, the thread store and the model cache; and the login itself,
  -- bound as the file the link in `home` names, written in place.
  add(rw, home)
  add(rw, login)
  add(rw, M.shell_home())
  return { ro = ro, rw = rw }
end

return M
