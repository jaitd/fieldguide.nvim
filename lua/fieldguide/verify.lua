-- Verb: `verify` (§5.9) — a sandboxed headless boot of the working tree as it
-- is on disk. The feedback loop.
--
-- NOT a security control (§6). It boots and quits, so autocmd callbacks, keymap
-- RHS, `on_attach`, `defer_fn` and plugin `config` functions never run. A
-- payload in any of those returns "boot ok". `verify` answers "does this boot",
-- and nothing else.

local cfg = require("fieldguide.config")
local util = require("fieldguide.util")

local M = {}

---Result of the previous run, for the structured diff.
M.last = nil

---Where this file lives on disk, so the probe can be bound into the sandbox.
---Absolute: bwrap cannot resolve a relative mount source, and it fails the
---whole boot rather than the one mount.
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h")
end

-- Signals that code inside the sandbox tried to leave it. An alarm, not a gate
-- (§6): it only observes code that ran, so it catches accidents and naive
-- payloads and nothing sophisticated. It must never discard the agent's work.
local ESCAPE_PATTERNS = {
  { pattern = "Network is unreachable", kind = "network" },
  { pattern = "Temporary failure in name resolution", kind = "network" },
  { pattern = "Could not resolve host", kind = "network" },
  { pattern = "Failed to connect", kind = "network" },
  { pattern = "[Rr]ead%-only file system", kind = "write" },
  { pattern = "EROFS", kind = "write" },
  { pattern = "E886", kind = "write" }, -- ShaDa on a read-only state dir
  -- seatbelt has no read-only mounts, so a denied write comes back as EPERM
  -- rather than EROFS. Both halves of that message appear.
  { pattern = "Operation not permitted", kind = "denied" },
  { pattern = "EPERM", kind = "denied" },
}

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

-- Which sandbox this machine has. bwrap is the reference implementation and
-- the one §6 describes; seatbelt (`sandbox-exec`) is the macOS stand-in, and
-- the two do not isolate the same way — see `seatbelt_plan` for what is and is
-- not equivalent. `verify.sandbox` pins one; "auto" picks by OS.
---@return string? backend, string? err
local function backend()
  local want = cfg.options.verify.sandbox or "auto"
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
        ("verify.sandbox = %q, but %s is not on PATH."):format(want, want == "bwrap" and "bwrap" or "sandbox-exec")
    end
    return nil, ('verify.sandbox = %q is not a sandbox. Use "auto", "bwrap" or "seatbelt".'):format(tostring(want))
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
    darwin and "sandbox-exec not found. verify runs the boot sandboxed and will not fall back to an unsandboxed one."
      or "bwrap (bubblewrap) not found on PATH. verify runs the boot sandboxed and "
        .. "will not fall back to an unsandboxed one."
end

-- Under bwrap the config tree is mounted here and pointed at with
-- XDG_CONFIG_HOME, rather than bound back onto whatever path nvim reported.
-- One mechanism covers a plain ~/.config/nvim, a dotfiles symlink, an
-- NVIM_APPNAME variant, and a fixture directory under test. seatbelt reaches
-- the same place with a symlink, for want of anything to mount.
local SANDBOX_CONFIG_HOME = "/tmp/fieldguide-config"
local SANDBOX_PROBE = "/tmp/fieldguide-probe.lua"

---Minimal environment. `NVIM` and `FIELDGUIDE_ADDR` are absent by
---construction, so nothing inside the sandbox can reach back to the live editor
---even if the tool list is loosened later (§6).
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
local function bwrap_plan(config_dir)
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
  add("--tmpfs", "/tmp")

  -- Read-only, so `lazy-lock.json` — which lives inside the config tree — is
  -- not rewritten by the boot that is only supposed to observe it.
  add("--ro-bind", config_dir, SANDBOX_CONFIG_HOME .. "/" .. (vim.env.NVIM_APPNAME or "nvim"))
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

---macOS. `sandbox-exec` is not bwrap and this is not the same sandbox (§6):
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
local function seatbelt_plan(config_dir)
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

---@param text string
---@return table?, string
local function extract_payload(text)
  local body = text:match("<<<FIELDGUIDE%s*(.-)%s*FIELDGUIDE>>>")
  local rest = text:gsub("\n?<<<FIELDGUIDE.-FIELDGUIDE>>>\n?", "")
  if not body then
    return nil, rest
  end
  local ok, decoded = pcall(vim.json.decode, body)
  return ok and decoded or nil, rest
end

---@param stderr string
---@param stdout string
---@return table[]
local function escape_alarms(stderr, stdout)
  local alarms = {}
  local haystack = stderr .. "\n" .. stdout
  for _, e in ipairs(ESCAPE_PATTERNS) do
    for line in haystack:gmatch("[^\n]+") do
      if line:find(e.pattern) then
        table.insert(alarms, { kind = e.kind, line = vim.trim(line) })
        break
      end
    end
  end
  return alarms
end

---@param a table?
---@param b table
---@return table?
local function diff(a, b)
  if not a then
    return nil
  end
  local d = {}
  if a.ok ~= b.ok then
    d.ok = { from = a.ok, to = b.ok }
  end
  local before = {}
  for _, e in ipairs(a.errors or {}) do
    before[e] = true
  end
  local new_errors = {}
  for _, e in ipairs(b.errors or {}) do
    if not before[e] then
      table.insert(new_errors, e)
    end
  end
  local after = {}
  for _, e in ipairs(b.errors or {}) do
    after[e] = true
  end
  local fixed = {}
  for _, e in ipairs(a.errors or {}) do
    if not after[e] then
      table.insert(fixed, e)
    end
  end
  if #new_errors > 0 then
    d.new_errors = new_errors
  end
  if #fixed > 0 then
    d.fixed_errors = fixed
  end
  -- Timing always moves a little; it is context, not a change. `unchanged` has
  -- to mean "nothing you did shows up here", or the diff stops being readable.
  d.unchanged = next(d) == nil or nil
  if a.duration_ms and b.duration_ms then
    d.duration_delta_ms = math.floor((b.duration_ms - a.duration_ms) * 10) / 10
  end
  return d
end

---Everything up to and including building the full argv (sandbox launcher +
---`nvim --headless … qa!`), but does not spawn anything. Split out of M.run so
---the spawn + wait can happen in a process other than the live editor (the
---CLI, for `verify`, is its own `nvim -l` and can block freely — see
---bin/fieldguide) while the plan itself is still built from *this* editor's
---config.
---@param args table { timeout_ms?: integer }
---@return table plan { ok: boolean, error?: string, argv?: string[], cwd?: string, env?: table, timeout_ms?: integer, sandbox?: string, temp?: string[] }
function M.plan(args)
  args = args or {}
  local which, err = backend()
  if not which then
    return { ok = false, error = err }
  end

  local p = cfg.paths()
  -- Deliberately not an argument: the verb surface stays closed, and a test
  -- points it at a fixture with cfg.setup({ cwd = … }) instead.
  local ok_plan, plan = pcall(which == "seatbelt" and seatbelt_plan or bwrap_plan, p.config_dir)
  if not ok_plan then
    return { ok = false, error = ("failed to prepare the %s sandbox: %s"):format(which, tostring(plan)) }
  end

  local argv = vim.deepcopy(plan.argv)
  vim.list_extend(argv, {
    p.nvim_bin or "nvim",
    "--headless",
    "--cmd",
    "lua vim.g.__fieldguide_t0 = vim.uv.hrtime()",
    "-c",
    "luafile " .. plan.probe,
    "-c",
    "qa!",
  })

  return {
    ok = true,
    sandbox = which,
    argv = argv,
    cwd = p.config_dir,
    env = plan.env,
    timeout_ms = args.timeout_ms or cfg.options.verify.timeout_ms,
    -- Paths a run of this plan must remove once it is done with them — the
    -- caller who spawns the process is the one who cleans up, not `plan`
    -- itself (§ design: the CLI runs the child, so the CLI does this).
    temp = plan.temp or {},
  }
end

---Remove the temp paths a plan (from M.plan or M.run's own use of it) named.
---Safe to call on a plan whose `ok` is false — `temp` is simply absent.
---@param plan table
function M.cleanup(plan)
  for _, path in ipairs((plan or {}).temp or {}) do
    vim.fn.delete(path, "rf")
  end
end

---Turn a finished child process's result into the same shape M.run has
---always returned. `res` is `vim.system`'s wait() result (or the equivalent
---assembled by the CLI from its own vim.system call); `opts` carries what the
---plan knew and the caller measured.
---@param res table { code: integer, signal?: integer, stdout?: string, stderr?: string }
---@param opts table { duration_ms: number, timeout_ms: integer, sandbox?: string }
---@return table result
function M.interpret(res, opts)
  local duration_ms = opts.duration_ms
  local timeout = opts.timeout_ms
  local which = opts.sandbox

  if res.code == 124 or res.signal == 15 and duration_ms >= timeout then
    local result = { ok = false, timed_out = true, duration_ms = duration_ms, errors = { "boot timed out" } }
    M.last = result
    return result
  end

  local stdout = res.stdout or ""
  local stderr = res.stderr or ""
  local payload, clean_stdout = extract_payload(stdout)

  -- A sandbox that never started is not a config that failed to boot, and it
  -- is certainly not an escape alarm — bwrap's own "Operation not permitted"
  -- matches the same pattern a denied write does. Both launchers prefix their
  -- errors with their name, and neither can have produced a probe payload.
  if res.code ~= 0 and payload == nil then
    local line = stderr:match("^%s*(bwrap: [^\n]+)") or stderr:match("^%s*(sandbox%-exec: [^\n]+)")
    if line then
      return {
        ok = false,
        sandbox = which,
        error = ("the %s sandbox failed to start: %s"):format(which, vim.trim(line)),
      }
    end
  end

  -- Startup errors land on stderr with their tracebacks; :messages catches the
  -- rest. Both are the answer to "what broke".
  local errors = {}
  for line in stderr:gmatch("[^\n]+") do
    if line:match("^E%d+:") or line:match("Error") or line:match("^stack traceback") or line:match("^%s+%.%.%.") then
      table.insert(errors, vim.trim(line))
    end
  end
  if payload and payload.errmsg then
    table.insert(errors, payload.errmsg)
  end

  local result = {
    ok = res.code == 0 and #errors == 0,
    sandbox = which,
    exit_code = res.code,
    duration_ms = duration_ms,
    startup_ms = payload and payload.startup_ms or nil,
    errors = errors,
    messages = payload and payload.messages or nil,
    plugins = payload and payload.plugins or nil,
    stderr = stderr ~= "" and vim.trim(stderr) or nil,
    stdout = vim.trim(clean_stdout) ~= "" and vim.trim(clean_stdout) or nil,
    probe_missing = payload == nil or nil,
    escape_alarms = nil,
  }

  local alarms = escape_alarms(stderr, stdout)
  if #alarms > 0 then
    result.escape_alarms = alarms
    result.escape_alarm_note = "Code inside the sandbox attempted network or write access. "
      .. "This is an alarm, not a verdict — review it; nothing was reverted."
  end

  if payload and payload.plugins and #payload.plugins.would_install > 0 then
    result.note = ("would install %s — not verified. verify boots what is on disk, offline."):format(
      table.concat(payload.plugins.would_install, ", ")
    )
  end

  result.diff = diff(M.last, result)
  M.last = result
  return result
end

---@param args table { timeout_ms?: integer }
function M.run(args)
  local plan = M.plan(args)
  if not plan.ok then
    return { ok = false, error = plan.error }
  end

  local t0 = vim.uv.hrtime()
  local ok_spawn, proc = pcall(vim.system, plan.argv, {
    cwd = plan.cwd,
    env = plan.env,
    clear_env = true,
    text = true,
  })
  if not ok_spawn then
    M.cleanup(plan)
    return { ok = false, error = "failed to spawn sandbox: " .. tostring(proc) }
  end

  local res = proc:wait(plan.timeout_ms)
  local duration_ms = math.floor((vim.uv.hrtime() - t0) / 1e4) / 100
  M.cleanup(plan)

  return M.interpret(res, { duration_ms = duration_ms, timeout_ms = plan.timeout_ms, sandbox = plan.sandbox })
end

---Which sandbox this machine would use, and why not, if it would not.
---@return string? backend, string? err
function M.sandbox()
  return backend()
end

---Test-only: build a sandbox plan without spawning anything, so a test can
---inspect the argv list — e.g. that a stow-style config's link targets are
---bound — on a machine that may not even have the backend installed. Not
---part of the verb surface (§6): the verb itself takes no backend argument.
---@param which "bwrap"|"seatbelt"
---@param config_dir string
---@return table plan
function M._plan(which, config_dir)
  return (which == "seatbelt" and seatbelt_plan or bwrap_plan)(config_dir)
end

---One line, for the sidebar and for appending to a write tool's own result.
---@param r table
---@return string
function M.summary(r)
  if r.error then
    return "verify unavailable: " .. r.error
  end
  if r.timed_out then
    return ("boot TIMED OUT after %.0fms"):format(r.duration_ms)
  end
  if r.ok then
    local s = ("boot OK, %.0fms"):format(r.duration_ms)
    if r.note then
      s = s .. " (" .. r.note .. ")"
    end
    return s
  end
  return ("boot FAILED: %s"):format(r.errors[1] or ("exit=" .. tostring(r.exit_code)))
end

return M
