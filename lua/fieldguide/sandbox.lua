-- The sandboxes: bwrap on Linux, seatbelt (`sandbox-exec`) on macOS.
--
-- Two things are run inside one. `verify` boots the config offline and throws
-- away everything it wrote; the agent itself, under any harness other than pi,
-- runs with the config tree writable and nothing else of $HOME in reach. They
-- share the backend choice and the path discovery (plugin dirs, stow link
-- targets), and differ in what they bind and whether the network is there.

local cfg = require("fieldguide.config")
local util = require("fieldguide.util")

local M = {}

---Where this file lives on disk, so the probe can be bound into the sandbox.
---Absolute: bwrap cannot resolve a relative mount source, and it fails the
---whole boot rather than the one mount.
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h")
end

---Installed plugin directories that the other mounts do not already cover.
---@return string[]
local function local_plugin_dirs()
  local ok, lazy_cfg = pcall(require, "lazy.core.config")
  if not ok then
    return {}
  end
  local p = cfg.paths()
  local seen, out = {}, {}
  for _, plugin in pairs(lazy_cfg.plugins) do
    local dir = plugin.dir and util.resolve(plugin.dir) or nil
    if
      dir
      and not seen[dir]
      and vim.uv.fs_stat(dir)
      and not util.is_under(dir, p.data_dir)
      and not util.is_under(dir, p.config_dir)
    then
      seen[dir] = true
      table.insert(out, dir)
    end
  end
  table.sort(out)
  return out
end

-- Which sandbox this machine has. bwrap is the reference implementation;
-- seatbelt (`sandbox-exec`) is the macOS backend, and the two do not isolate
-- the same way — see `verify_seatbelt` for what is and is not equivalent.
-- `setting` names the option that pinned one, and `purpose` says what refuses
-- to run without one, so each caller's error reads as its own.
---@param want string? "auto" | "bwrap" | "seatbelt"
---@param setting string the option name, for the error message
---@param purpose string e.g. "verify runs the boot sandboxed"
---@return string? backend, string? err
function M.backend(want, setting, purpose)
  want = want or "auto"
  local have = {
    bwrap = vim.fn.executable("bwrap") == 1,
    seatbelt = vim.fn.executable("sandbox-exec") == 1,
  }

  if want ~= "auto" then
    if have[want] then
      return want
    end
    if want == "bwrap" or want == "seatbelt" then
      return nil,
        ("%s = %q, but %s is not on PATH."):format(setting, want, want == "bwrap" and "bwrap" or "sandbox-exec")
    end
    return nil, ('%s = %q is not a sandbox. Use "auto", "bwrap" or "seatbelt".'):format(setting, tostring(want))
  end

  local darwin = vim.uv.os_uname().sysname == "Darwin"
  if darwin and have.seatbelt then
    return "seatbelt"
  end
  if have.bwrap then
    return "bwrap"
  end
  if have.seatbelt then
    return "seatbelt"
  end
  return nil,
    darwin and ("sandbox-exec not found. %s and will not fall back to an unsandboxed one."):format(purpose)
      or ("bwrap (bubblewrap) not found on PATH. %s and will not fall back to an unsandboxed one."):format(purpose)
end

-- The config tree is reached through a link here, pointed at with
-- XDG_CONFIG_HOME, rather than through whatever path nvim reported. One
-- mechanism covers a plain ~/.config/nvim, a dotfiles symlink, an NVIM_APPNAME
-- variant, and a fixture directory under test. A link and not a mount: under
-- bwrap the tree itself is bound at its own path, so the relative links GNU
-- stow makes resolve where they were written and not against this directory.
local SANDBOX_CONFIG_HOME = "/tmp/fieldguide-config"
local SANDBOX_PROBE = "/tmp/fieldguide-probe.lua"

---Minimal environment. `NVIM` and `FIELDGUIDE_ADDR` are absent by
---construction, so nothing inside the sandbox can reach back to the live editor
---even if the tool list is loosened later.
---
---Deliberately *no* FIELDGUIDE_VERIFY marker: a config could branch on it, and
---a flag that lets a payload skip verification is worse than no flag.
---
---@param extra table? backend-specific overrides, applied last
---@return table
local function child_env(extra)
  local env = {
    HOME = vim.uv.os_homedir(),
    PATH = vim.env.PATH,
    TERM = "dumb",
    LANG = vim.env.LANG or "C.UTF-8",
    USER = vim.env.USER,
  }
  for _, key in ipairs({ "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "NVIM_APPNAME" }) do
    if vim.env[key] then
      env[key] = vim.env[key]
    end
  end
  -- Where the boot's state goes is the backend's business: bwrap tmpfs'es the
  -- real paths and can leave them named, seatbelt has to point them elsewhere.
  return vim.tbl_extend("force", env, extra or {})
end

---Directories the config tree symlinks *out* to. A dotfiles manager that
---symlinks the tree wholesale is covered by resolving `config_dir`, but stow
---and friends link file by file: `~/.config/nvim` is a real directory full of
---links into `~/dev/dotfiles`, and a rule naming only the config dir reaches
---the links and not what they point at. $HOME itself is never added back —
---a link straight to it would undo the deny it is meant to work around.
---@param config_dir string
---@return string[]
local function config_link_targets(config_dir)
  local home = cfg.paths().home
  local seen, out = {}, {}
  for name, kind in vim.fs.dir(config_dir, { depth = 8 }) do
    if kind == "link" then
      local target = vim.uv.fs_realpath(config_dir .. "/" .. name)
      local dir = target and vim.fn.fnamemodify(target, ":h") or nil
      if dir and dir ~= home and not seen[dir] and not util.is_under(dir, config_dir) then
        seen[dir] = true
        table.insert(out, dir)
      end
    end
  end
  table.sort(out)
  return out
end

---@param config_dir string
---@return table plan { argv: string[], env: table, temp: string[]? }
local function verify_bwrap(config_dir)
  local p = cfg.paths()
  local home = p.home
  local argv = {
    "bwrap",
    "--ro-bind",
    "/",
    "/",
    -- Everything in $HOME disappears, then only what the boot needs comes back.
    -- SSH keys, shell history and secrets files are unreachable even if the
    -- path gate above has a bug.
    "--tmpfs",
    home,
    -- /tmp before anything is bound, like $HOME above: a data dir, a stow
    -- tree or a local plugin under /tmp would otherwise be mounted and then
    -- buried by this tmpfs, and a state dir there that does not exist yet
    -- could not be created under the read-only root at all.
    "--tmpfs",
    "/tmp",
  }

  local function add(...)
    for _, v in ipairs({ ... }) do
      table.insert(argv, v)
    end
  end

  -- Binds already placed at their own path, so the loop below does not lay a
  -- second --ro-bind over one that already covers a given directory.
  local bound = {}

  -- nvim may be a tarball install under $HOME; bind its prefix back.
  if p.nvim_prefix and util.is_under(p.nvim_prefix, home) then
    add("--ro-bind", p.nvim_prefix, p.nvim_prefix)
    bound[p.nvim_prefix] = true
  end

  if p.data_dir and vim.uv.fs_stat(p.data_dir) then
    add("--ro-bind", p.data_dir, p.data_dir)
    bound[p.data_dir] = true
  end

  -- Plugins developed locally live wherever the user put them — a `dir = …`
  -- spec pointing at a working tree in $HOME, outside both the config tree and
  -- the data dir. $HOME is a tmpfs in here, so without this they vanish, lazy
  -- decides they need installing, and verify reports a failure that says more
  -- about the sandbox than about the config.
  for _, dir in ipairs(local_plugin_dirs()) do
    add("--ro-bind", dir, dir)
    bound[dir] = true
  end

  -- A stow-style config symlinks file by file into a dotfiles tree outside
  -- both the config dir and the data dir — see `config_link_targets`. $HOME
  -- is a tmpfs in here, so without these the links dangle, lazy decides the
  -- plugins they point at need installing, and verify reports a failure that
  -- says more about the sandbox than about the config. Bound after the
  -- --tmpfs above, not before: bwrap layers later binds over earlier ones, so
  -- earlier would leave these mounts sitting under the tmpfs and unreachable.
  for _, dir in ipairs(config_link_targets(config_dir)) do
    if not bound[dir] then
      add("--ro-bind", dir, dir)
      bound[dir] = true
    end
  end

  -- ShaDa, swap and lazy's state need somewhere to go. --tmpfs, not a relaxed
  -- mount: `E886: … read-only file system` is what the relaxed version costs.
  add("--tmpfs", vim.fn.stdpath("state"))
  add("--tmpfs", vim.fn.stdpath("cache"))

  -- Read-only, so `lazy-lock.json` — which lives inside the config tree — is
  -- not rewritten by the boot that is only supposed to observe it. After the
  -- /tmp tmpfs, which would otherwise bury a config that lives under /tmp.
  add("--ro-bind", config_dir, config_dir)
  add("--symlink", config_dir, SANDBOX_CONFIG_HOME .. "/" .. (vim.env.NVIM_APPNAME or "nvim"))
  add("--ro-bind", plugin_root() .. "/probe.lua", SANDBOX_PROBE)

  add("--dev", "/dev", "--proc", "/proc")
  add("--unshare-net", "--unshare-pid", "--die-with-parent", "--new-session")

  return { argv = argv, env = child_env({ XDG_CONFIG_HOME = SANDBOX_CONFIG_HOME }), probe = SANDBOX_PROBE }
end

---One path, as a seatbelt profile literal.
---@param path string
---@return string
local function sbpl(path)
  return '"' .. path:gsub('[\\"]', "\\%0") .. '"'
end

---macOS. `sandbox-exec` is not bwrap and this is not the same sandbox:
---seatbelt has no mount namespace, so nothing is *bound* anywhere and nothing
---is a tmpfs. The boot starts with the whole machine and has things taken away
---from it, which is the opposite direction of travel and worth saying out loud:
---
---  bwrap                              seatbelt
---  ro-bind / and tmpfs $HOME          allow default, then deny
---  config bound in read-only          config symlinked in, writes denied
---  state/cache/tmp are tmpfs          state/cache/tmp are XDG-pointed at a box
---  --unshare-net                      (deny network*), unix sockets kept
---  --unshare-pid, --new-session       no equivalent
---
---The three properties `verify` actually leans on survive: the config tree
---cannot be written, the boot cannot reach the network, and everything it does
---write lands in a directory that is deleted afterwards. Process isolation does
---not survive, and a denied read is EPERM here rather than a file that is
---simply absent.
---
---@param config_dir string
---@return table plan
local function verify_seatbelt(config_dir)
  local p = cfg.paths()

  -- Somewhere to put ShaDa, swap and lazy's state — the box that stands in for
  -- three tmpfs mounts. Created before it is resolved: `tempname` names a path
  -- that does not exist yet, and /var is a symlink to /private/var, which the
  -- profile has to be told about in its resolved form or every rule misses.
  local box = vim.fn.tempname()
  for _, sub in ipairs({ "config", "state", "cache", "tmp" }) do
    vim.fn.mkdir(box .. "/" .. sub, "p")
  end
  box = util.resolve(box)

  -- A symlink is what stands in for --ro-bind: it puts the config tree under a
  -- directory named for the appname, so XDG_CONFIG_HOME reaches it whatever the
  -- tree is really called. Writes through it are denied by the profile, so the
  -- read-only half of the bind holds too.
  vim.uv.fs_symlink(config_dir, box .. "/config/" .. (vim.env.NVIM_APPNAME or "nvim"))

  local readable = { config_dir, box, plugin_root() }
  if p.data_dir and vim.uv.fs_stat(p.data_dir) then
    table.insert(readable, p.data_dir)
  end
  if p.nvim_prefix then
    table.insert(readable, p.nvim_prefix)
  end
  vim.list_extend(readable, local_plugin_dirs())
  vim.list_extend(readable, config_link_targets(config_dir))

  local allow_read = {}
  for _, dir in ipairs(readable) do
    table.insert(allow_read, "  (subpath " .. sbpl(dir) .. ")")
  end

  local profile = table.concat({
    "(version 1)",
    "(allow default)",
    "",
    ";; No network. Unix sockets stay: nvim opens its own server socket at",
    ";; startup, and losing it fails the boot for a reason that has nothing to",
    ";; do with the config being verified.",
    "(deny network*)",
    "(allow network* (remote unix-socket) (local unix-socket))",
    "",
    ";; Read-only everywhere but the box. One rule covers the config tree,",
    ";; lazy-lock.json inside it, and the data dir.",
    "(deny file-write*)",
    "(allow file-write* (subpath " .. sbpl(box) .. "))",
    '(allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper") (regex #"^/dev/tty"))',
    "",
    ";; $HOME goes away the way --tmpfs makes it go away under bwrap, and only",
    ";; what the boot needs comes back. SSH keys and shell history are",
    ";; unreachable even if the path gate has a bug.",
    "(deny file-read* (subpath " .. sbpl(p.home) .. "))",
    "(allow file-read*",
    table.concat(allow_read, "\n"),
    ")",
    "",
  }, "\n")

  local profile_path = box .. "/verify.sb"
  local fd = assert(io.open(profile_path, "w"))
  fd:write(profile)
  fd:close()

  local argv = { "sandbox-exec", "-f", profile_path }
  return {
    argv = argv,
    env = child_env({
      XDG_CONFIG_HOME = box .. "/config",
      XDG_STATE_HOME = box .. "/state",
      XDG_CACHE_HOME = box .. "/cache",
      TMPDIR = box .. "/tmp",
    }),
    probe = plugin_root() .. "/probe.lua",
    -- Removed once the run that used this plan is done with it — by
    -- M.cleanup, called by whichever process actually spawned the child
    -- (M.run itself, or the CLI when the plan crossed an RPC boundary).
    temp = { box },
  }
end

---The boot plan `verify` runs: argv prefix, environment, where the probe is,
---and any temp paths the caller removes afterwards.
---@param which "bwrap"|"seatbelt"
---@param config_dir string
---@return table plan { argv: string[], env: table, probe: string, temp: string[]? }
function M.verify_plan(which, config_dir)
  return (which == "seatbelt" and verify_seatbelt or verify_bwrap)(config_dir)
end

-- The agent sandbox.
--
-- Under pi the path gate lives in the extension, in front of every file tool.
-- Other harnesses carry their own tools, and their hooks see arguments in
-- shapes the gate would have to be taught one at a time: a Glob pattern
-- holding `../`, a patch whose paths are inside its text, a shell command
-- string. Taught one at a time is how a gate misses one. So the harness
-- process runs in here, and the zones become what exists rather than what a
-- hook decides to allow:
--
--   config tree        read/write   bound at its real path
--   doc roots          read-only    lazy's plugin dir, $VIMRUNTIME
--   fieldguide itself  read-only    the MCP server and the CLI its tools call
--   the rest of $HOME  absent       a tmpfs, whatever the harness does
--
-- What is deliberately still possible, and why:
--
-- - The network. The harness has to reach its model provider, and bwrap has
--   no allowlist by host: it is all of the network or none of it. What the
--   network can carry out is bounded by what is readable in here, which is
--   why that list is short.
-- - Its own credentials. A harness cannot log in with a token it cannot read,
--   so `needs()` binds them back. A prompt-injected agent can read that token.
--   It cannot read anything else of yours.
-- - Calling fieldguide's tools, over the one socket bound in: the MCP server,
--   which runs out here with the editor. Anything that connects to it gets the
--   tools the agent already has, and nothing else.
--
-- What is never bound in is the editor's own RPC socket. The closed verb
-- table is enforced by bin/fieldguide, a client, and an agent with a shell
-- does not have to use that client: one `nvim --server … --remote-expr` and
-- it runs Lua in the unsandboxed editor. `agent_plan` refuses any plan that
-- would leave one of this editor's addresses within reach.

---Top-level system directories a binary needs to run at all. Allowlisted
---rather than `--ro-bind / /` and subtracting, as `verify` does: verify runs a
---config, but some harnesses hand the agent a shell, and a shell finds
---whatever a subtraction forgot — other users' homes, /mnt, a stray readable
---file in /tmp, the ssh-agent socket under /run/user.
local SYSTEM_DIRS = { "/usr", "/etc", "/opt", "/nix" }
---Symlinks into /usr on a merged-/usr system, real directories elsewhere.
---Recreated as whichever they are, so the dynamic loader finds itself.
local SYSTEM_LINKS = { "/bin", "/sbin", "/lib", "/lib32", "/lib64" }

---The repository root: `extension/` and `bin/fieldguide` live here, and the
---harness spawns the MCP server from the first, which calls the second.
---@return string
local function repo_root()
  return vim.fn.fnamemodify(plugin_root(), ":h:h")
end

---The install prefix of an executable on PATH, resolved: a version manager's
---shim under $HOME is a symlink into an install that is also under $HOME,
---and both vanish with the tmpfs unless bound back.
---@param exe string
---@return string?
local function prefix_of(exe)
  local path = vim.fn.exepath(exe)
  if path == "" then
    return nil
  end
  return vim.fn.fnamemodify(util.resolve(path), ":h:h")
end

---@class fieldguide.AgentZones
---@field config_dir string resolved config tree, read/write
---@field config_dir_declared string? the path nvim reports, when a symlink leads to config_dir
---@field doc_roots string[] read-only
---@field extra_ro string[]? from the harness's needs()
---@field extra_rw string[]? from the harness's needs()
---@field mcp_socket string? the MCP server's socket (`mcp.ts --listen`), never the editor's
---@field cwd string? defaults to config_dir
---@field sandbox string? "auto" | "bwrap" | "seatbelt"

---Every path the agent gets back, with its mode, parents before children.
---bwrap applies mounts in order, so a writable directory inside a read-only
---one has to come second to win — and the reverse holds too: a doc root that
---happens to sit inside the config tree stays read-only because it is the
---longer path.
---@param z fieldguide.AgentZones
---@return { path: string, rw: boolean }[]
local function agent_binds(z)
  local p = cfg.paths()
  local binds, seen = {}, {}
  local function add(path, rw)
    if not path or path == "" or seen[path] then
      return
    end
    seen[path] = true
    table.insert(binds, { path = path, rw = rw })
  end

  add(z.config_dir, true)
  for _, dir in ipairs(z.doc_roots or {}) do
    add(dir, false)
  end
  add(repo_root(), false)
  -- The tools shell out to `nvim -l bin/fieldguide` and to node, and both are
  -- commonly installed under $HOME by a version manager.
  add(p.nvim_prefix, false)
  add(prefix_of("node"), false)
  -- Read-only, as under verify: a stow-style config is a directory of links
  -- into a dotfiles tree, and without the targets every link dangles. Not
  -- writable: the target directory may hold far more than the Neovim config,
  -- and the path gate never granted it either.
  for _, dir in ipairs(config_link_targets(z.config_dir)) do
    add(dir, false)
  end
  for _, dir in ipairs(z.extra_ro or {}) do
    add(dir, false)
  end
  for _, dir in ipairs(z.extra_rw or {}) do
    add(dir, true)
  end
  if z.mcp_socket then
    add(z.mcp_socket, true)
  end

  table.sort(binds, function(a, b)
    if #a.path ~= #b.path then
      return #a.path < #b.path
    end
    return a.path < b.path
  end)
  return binds
end

---@param z fieldguide.AgentZones
---@return string[]
local function agent_bwrap(z)
  local home = cfg.paths().home
  local argv = { "bwrap" }
  local function add(...)
    vim.list_extend(argv, { ... })
  end

  for _, dir in ipairs(SYSTEM_DIRS) do
    add("--ro-bind-try", dir, dir)
  end
  for _, dir in ipairs(SYSTEM_LINKS) do
    local target = vim.uv.fs_readlink(dir)
    if target then
      add("--symlink", target, dir)
    else
      add("--ro-bind-try", dir, dir)
    end
  end
  -- /etc/resolv.conf is a symlink into here under systemd-resolved; without it
  -- the harness has a network and no way to name anything on it.
  add("--ro-bind-try", "/run/systemd/resolve", "/run/systemd/resolve")
  add("--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp")

  -- Empty rather than absent: harnesses put sockets and locks under
  -- $XDG_RUNTIME_DIR, and the real one holds the ssh and gpg agents' sockets.
  local runtime = vim.env.XDG_RUNTIME_DIR
  if runtime and runtime ~= "" then
    add("--tmpfs", runtime)
  end
  -- Everything in $HOME disappears; the binds below bring back what the zones
  -- and the harness need. After the tmpfs, or they would sit underneath it.
  add("--tmpfs", home)

  local binds = agent_binds(z)
  for _, b in ipairs(binds) do
    -- Not -try: a zone that silently fails to appear is a harness that
    -- starts, cannot find its credentials or the config, and blames the user.
    add(b.rw and "--bind" or "--ro-bind", b.path, b.path)
  end

  -- The agent works at the resolved path, but the user's own words, lazy's
  -- specs and :help output name the declared one. A symlink, not a second
  -- bind, so there is exactly one way in to each file.
  local declared = z.config_dir_declared
  if declared and declared ~= z.config_dir then
    local covered = false
    for _, b in ipairs(binds) do
      covered = covered or util.is_under(declared, b.path)
    end
    if not covered then
      add("--symlink", z.config_dir, declared)
    end
  end

  -- The editor's address is no use in here and is not left lying around: the
  -- MCP server outside is what talks to it.
  add("--unsetenv", "NVIM", "--unsetenv", "NVIM_LISTEN_ADDRESS", "--unsetenv", "FIELDGUIDE_ADDR")
  add("--chdir", z.cwd or z.config_dir)
  -- Its own PID namespace: the agent cannot signal or ptrace the editor, or
  -- read /proc/<pid>/environ of anything else you run. The network namespace
  -- is the one left shared; see the top of this section.
  add("--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try")
  -- --new-session: no TIOCSTI into the terminal that launched the editor.
  add("--die-with-parent", "--new-session", "--")
  return argv
end

---macOS, by the same rules and with the same caveats as `verify_seatbelt`:
---nothing is bound, so the agent starts with the whole machine and has $HOME
---taken away. Weaker than bwrap in three ways worth knowing: there is no PID
---isolation, /tmp stays readable, and a denied read is EPERM rather than a
---file that does not exist. Writes are denied everywhere except the config
---tree, the harness's own state and the per-user temp dir.
---@param z fieldguide.AgentZones
---@return string[]
local function agent_seatbelt(z)
  local home = cfg.paths().home
  local readable, writable = {}, {}
  for _, b in ipairs(agent_binds(z)) do
    table.insert(readable, "  (subpath " .. sbpl(b.path) .. ")")
    if b.rw then
      table.insert(writable, "  (subpath " .. sbpl(b.path) .. ")")
    end
  end
  local tmpdir = vim.env.TMPDIR
  if tmpdir and tmpdir ~= "" then
    table.insert(writable, "  (subpath " .. sbpl(util.resolve(tmpdir)) .. ")")
  end

  local profile = table.concat({
    "(version 1)",
    "(allow default)",
    "",
    ";; The network stays: the harness has to reach its model provider.",
    "",
    "(deny file-read* (subpath " .. sbpl(home) .. "))",
    "(allow file-read*",
    table.concat(readable, "\n"),
    ")",
    "",
    "(deny file-write*)",
    "(allow file-write*",
    table.concat(writable, "\n"),
    ")",
    '(allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper") (regex #"^/dev/tty"))',
    "",
  }, "\n")

  -- Inline with -p rather than a profile file: there is then nothing to clean
  -- up, and nothing the agent could rewrite between turns.
  return { "sandbox-exec", "-p", profile, "--" }
end

---Why this editor would be reachable from inside a plan, or nil if it would
---not be. Its unix sockets normally sit under $XDG_RUNTIME_DIR or /tmp, both
---empty in here; the cases that matter are a socket passed in as the MCP one,
---a socket inside a zone that is bound back, and a TCP listener, which the
---shared network reaches wherever it is. Another Neovim's addresses cannot be
---enumerated from here; under /tmp and the runtime dir they are hidden alike.
---@param z fieldguide.AgentZones
---@return string?
local function editor_reachable(z)
  local addresses = vim.fn.serverlist()
  for _, name in ipairs({ vim.v.servername, vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS }) do
    if name and name ~= "" then
      table.insert(addresses, name)
    end
  end
  local binds = agent_binds(z)
  for _, addr in ipairs(addresses) do
    if not addr:find("/", 1, true) and addr:find(":%d+$") then
      return ("this editor listens on TCP (%s), which the agent's network would reach"):format(addr)
    end
    local resolved = util.resolve(addr)
    if z.mcp_socket and resolved == util.resolve(z.mcp_socket) then
      return ("the MCP socket is this editor's own RPC socket (%s)"):format(addr)
    end
    for _, b in ipairs(binds) do
      if util.is_under(resolved, b.path) then
        return ("this editor's socket %s is inside %s, which the agent can reach"):format(addr, b.path)
      end
    end
  end
  return nil
end

---Wrap a harness's argv so it runs with only the agent zones in reach. Pure:
---builds the argv, spawns nothing, writes nothing.
---@param argv string[] the harness command line
---@param z fieldguide.AgentZones
---@return string[]? argv, string? err
function M.agent_plan(argv, z)
  if not z or not z.config_dir then
    return nil, "agent sandbox: no config_dir"
  end
  local which, err = M.backend(z.sandbox, "agent.sandbox", "fieldguide runs this harness sandboxed")
  if not which then
    return nil, err
  end
  local reachable = editor_reachable(z)
  if reachable then
    return nil, "agent sandbox: " .. reachable .. ". The agent would run Lua in the editor, outside the sandbox."
  end
  return M._agent_plan(which, argv, z)
end

---Test-only: build the argv for a named backend, so the seatbelt profile can
---be inspected on a machine without sandbox-exec.
---@param which "bwrap"|"seatbelt"
---@param argv string[]
---@param z fieldguide.AgentZones
---@return string[]
function M._agent_plan(which, argv, z)
  local out = which == "seatbelt" and agent_seatbelt(z) or agent_bwrap(z)
  vim.list_extend(out, argv)
  return out
end

return M
