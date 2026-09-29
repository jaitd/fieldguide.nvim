-- The sandboxes: bwrap on Linux, seatbelt (`sandbox-exec`) on macOS.
--
-- `verify` boots the config in one, offline, and throws away everything it
-- wrote. Kept apart from the verb so the backend choice and the path discovery
-- (plugin dirs, stow link targets) can be shared.

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

return M
