-- The agent sandbox: the argv it builds, and — where bwrap is installed — what
-- a shell inside it can and cannot reach.
--
--   nvim -l tests/sandbox.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")
local sandbox = require("fieldguide.sandbox")
local util = require("fieldguide.util")

local passed, failed, skipped = 0, 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.write(("  ok   %s\n"):format(name))
  else
    failed = failed + 1
    io.write(("  FAIL %s\n       %s\n"):format(name, detail or ""))
  end
end

---Position of the first `flag src dst` triple naming `dst`, or nil.
---@param argv string[]
---@param flag string
---@param dst string
---@return integer?
local function find(argv, flag, dst)
  for i = 1, #argv - 2 do
    if argv[i] == flag and argv[i + 2] == dst then
      return i
    end
  end
end

-- A fixture laid out the way the zones are: a config tree, a doc root, and a
-- canary beside them that must not exist from inside. Under /tmp, not
-- `tempname()`: on macOS that is inside $TMPDIR, which the agent may write,
-- and a canary there would be in reach by design. Resolved, because /tmp is a
-- link to /private/tmp there and the zones are real paths.
local box = util.resolve(assert(vim.uv.fs_mkdtemp("/tmp/fieldguide-sandbox-XXXXXX")))
local config_dir = box .. "/cfg"
local doc_root = box .. "/docs"
local outside = box .. "/outside"
for _, dir in ipairs({ config_dir, doc_root, outside }) do
  vim.fn.mkdir(dir, "p")
end
vim.fn.writefile({ "vim.g.fixture = 1" }, config_dir .. "/init.lua")
vim.fn.writefile({ "*fixture.txt*" }, doc_root .. "/fixture.txt")
vim.fn.writefile({ "CANARY-SECRET" }, outside .. "/secret.txt")

cfg.setup({ cwd = config_dir })
local home = cfg.paths().home

local zones = {
  config_dir = config_dir,
  doc_roots = { doc_root },
  extra_ro = {},
  extra_rw = {},
}

io.write("agent sandbox: bwrap argv\n")
do
  local argv = sandbox._agent_plan("bwrap", { "harness", "--flag" }, zones)
  local joined = table.concat(argv, " ")

  check("ends with the harness argv after --", argv[#argv - 2] == "--" and argv[#argv] == "--flag", joined)
  check("config tree is writable", find(argv, "--bind", config_dir) ~= nil, joined)
  check(
    "doc root is read-only",
    find(argv, "--ro-bind", doc_root) ~= nil and not find(argv, "--bind", doc_root),
    joined
  )
  check("the directory beside them is not bound", not joined:find(outside, 1, true), joined)
  check("root is not bound wholesale", find(argv, "--ro-bind", "/") == nil, joined)
  check("$HOME is a tmpfs", joined:find("--tmpfs " .. home, 1, true) ~= nil, joined)
  -- The network is shared on purpose; the PID namespace is not.
  check("network is shared", not joined:find("--unshare-net", 1, true), joined)
  check("pid namespace is not", joined:find("--unshare-pid", 1, true) ~= nil, joined)

  local tmpfs_home
  for i = 1, #argv - 1 do
    if argv[i] == "--tmpfs" and argv[i + 1] == home then
      tmpfs_home = i
    end
  end
  local first_bind = find(argv, "--bind", config_dir)
  check("binds come after the $HOME tmpfs", tmpfs_home and first_bind and first_bind > tmpfs_home, joined)
end

do
  -- A writable harness state dir inside a read-only credential dir: the
  -- child has to be mounted second or the parent's ro bind hides it.
  local argv = sandbox._agent_plan("bwrap", { "h" }, {
    config_dir = config_dir,
    doc_roots = {},
    extra_ro = { box .. "/creds" },
    extra_rw = { box .. "/creds/state" },
  })
  local parent = find(argv, "--ro-bind", box .. "/creds")
  local child = find(argv, "--bind", box .. "/creds/state")
  check(
    "a writable child is mounted after its read-only parent",
    parent and child and child > parent,
    table.concat(argv, " ")
  )
end

do
  local link = box .. "/declared-nvim"
  vim.uv.fs_symlink(config_dir, link)
  local argv = sandbox._agent_plan("bwrap", { "h" }, vim.tbl_extend("force", zones, { config_dir_declared = link }))
  check(
    "the declared config path is a symlink to the resolved one",
    find(argv, "--symlink", link) ~= nil and argv[find(argv, "--symlink", link) + 1] == config_dir,
    table.concat(argv, " ")
  )
end

do
  -- A stow-style config links file by file into a tree outside it; the links
  -- must resolve inside, and the tree they point into stays read-only.
  local stow = box .. "/stow"
  local dotfiles = box .. "/dotfiles"
  vim.fn.mkdir(stow, "p")
  vim.fn.mkdir(dotfiles, "p")
  vim.fn.writefile({ "-- stowed" }, dotfiles .. "/init.lua")
  vim.uv.fs_symlink(dotfiles .. "/init.lua", stow .. "/init.lua")
  local argv = sandbox._agent_plan("bwrap", { "h" }, { config_dir = stow, doc_roots = {} })
  check(
    "stow link targets are bound read-only",
    find(argv, "--ro-bind", dotfiles) ~= nil and not find(argv, "--bind", dotfiles),
    table.concat(argv, " ")
  )
end

-- The editor's own RPC socket runs arbitrary Lua outside the sandbox, so no
-- plan may leave it within reach. Addresses are started in this very process,
-- which is the editor as far as `agent_plan` can tell.
io.write("agent sandbox: never within reach of the editor\n")
if vim.fn.executable("bwrap") == 0 and vim.fn.executable("sandbox-exec") == 0 then
  skipped = skipped + 1
  io.write("  skip no sandbox backend installed\n")
else
  local function refused(extra, pattern)
    local argv, err = sandbox.agent_plan({ "h" }, vim.tbl_extend("force", zones, extra or {}))
    return argv == nil and (err or ""):find(pattern) ~= nil, err or table.concat(argv or {}, " ")
  end

  local own = vim.fn.serverstart(box .. "/own.sock")
  check("refused: the editor's socket passed as the MCP one", refused({ mcp_socket = own }, "own RPC socket"))
  vim.fn.serverstop(own)

  local inside_zone = vim.fn.serverstart(config_dir .. "/editor.sock")
  check("refused: an editor socket inside a bound zone", refused({}, "inside"))
  vim.fn.serverstop(inside_zone)

  local ok_tcp, tcp = pcall(vim.fn.serverstart, "127.0.0.1:0")
  if ok_tcp and tcp ~= "" then
    check("refused: an editor listening on TCP", refused({}, "TCP"))
    vim.fn.serverstop(tcp)
  else
    skipped = skipped + 1
    io.write("  skip this build cannot listen on TCP\n")
  end

  local argv = sandbox.agent_plan({ "h" }, vim.tbl_extend("force", zones, { mcp_socket = box .. "/mcp.sock" }))
  check("allowed: a separate MCP socket, with the editor out of reach", argv ~= nil)
end

io.write("agent sandbox: seatbelt profile\n")
do
  local argv = sandbox._agent_plan("seatbelt", { "harness" }, zones)
  local profile = argv[3] or ""
  check("inline profile, no file to clean up", argv[1] == "sandbox-exec" and argv[2] == "-p", table.concat(argv, " "))
  -- Denied everywhere and allowed back, as bwrap binds: denying $HOME alone
  -- left /tmp and every mounted volume readable to a shell with a network.
  check("reads are denied by default", profile:find("\n(deny file-read*)\n", 1, true) ~= nil, profile)
  check("writes are denied by default", profile:find("\n(deny file-write*)\n", 1, true) ~= nil, profile)
  check("the config tree is readable", profile:find('(subpath "' .. config_dir .. '")', 1, true) ~= nil, profile)
  check(
    "the doc root is not writable",
    not profile:find('(allow file-write* (subpath "' .. doc_root .. '"))', 1, true),
    profile
  )
  check("the network is not denied", not profile:find("(deny network*)", 1, true), profile)
  check(
    "unix sockets are, but for the MCP one",
    profile:find("(deny network-outbound (remote unix-socket))", 1, true) ~= nil,
    profile
  )
  check(
    "the editor's address is unset",
    table.concat(argv, " "):find("-u NVIM -u NVIM_LISTEN_ADDRESS -u FIELDGUIDE_ADDR harness", 1, true) ~= nil,
    table.concat(argv, " ")
  )
end

---What a shell inside the plan can and cannot reach, run for real.
---@param which "bwrap"|"seatbelt"
local function from_inside(which)
  -- A live editor, as a harness would run beside. Its socket is where Neovim
  -- puts one by default, which is never bound in — and on macOS is inside
  -- $TMPDIR, which the agent can read and write. A second Neovim stands in for
  -- the MCP server, the one socket that is meant to answer.
  local sock = vim.fn.tempname() .. ".sock"
  local mcp_sock = box .. "/mcp.sock"
  local server = vim.system({
    "nvim",
    "--headless",
    "--clean",
    "--listen",
    sock,
    "--cmd",
    "set rtp^=" .. root,
    "-c",
    ("lua require('fieldguide').setup({ cwd = %q })"):format(config_dir),
  })
  local mcp = vim.system({ "nvim", "--headless", "--clean", "--listen", mcp_sock })
  vim.wait(5000, function()
    return vim.uv.fs_stat(sock) ~= nil and vim.uv.fs_stat(mcp_sock) ~= nil
  end, 50)

  local argv = sandbox._agent_plan(
    which,
    { "sh", "-c", 'eval "$PROBE"' },
    vim.tbl_extend("force", zones, { mcp_socket = mcp_sock })
  )

  ---Run one shell probe inside the sandbox.
  ---@param script string
  ---@return vim.SystemCompleted
  local function inside(script)
    local env = vim.fn.environ()
    env.PROBE = script
    env.FIELDGUIDE_ADDR = sock
    env.NVIM = nil
    return vim.system(argv, { env = env, clear_env = true, text = true }):wait(20000)
  end

  local r = inside("cat " .. outside .. "/secret.txt")
  check("the canary beside the zones does not exist", r.code ~= 0 and not (r.stdout or ""):find("CANARY"), r.stdout)

  r = inside("test -e " .. home .. "/.ssh")
  check("~/.ssh does not exist", r.code ~= 0, vim.inspect(r))

  r = inside("echo x > " .. doc_root .. "/new.txt")
  -- EROFS under bwrap, EPERM under seatbelt: either way, refused by the kernel.
  check(
    "the doc root cannot be written",
    r.code ~= 0 and ((r.stderr or ""):find("Read%-only") or (r.stderr or ""):find("not permitted")) ~= nil,
    r.stderr
  )

  r = inside("echo written > " .. config_dir .. "/new.lua && cat " .. config_dir .. "/new.lua")
  check("the config tree can be written", r.code == 0 and vim.trim(r.stdout or "") == "written", vim.inspect(r))
  check("and the write is real, outside", vim.fn.filereadable(config_dir .. "/new.lua") == 1)

  r = inside("cat " .. doc_root .. "/fixture.txt")
  check("the doc root can be read", r.code == 0 and (r.stdout or ""):find("fixture") ~= nil, vim.inspect(r))

  -- The escape the sandbox exists to stop: straight to the editor's RPC socket,
  -- which runs Lua outside. By absolute path, as an agent would find it: the
  -- nvim install is bound read-only because the tools need it.
  r = inside(
    ("%q --headless --clean --server %q --remote-expr 'readfile(%q)[0]'"):format(
      cfg.paths().nvim_bin,
      sock,
      outside .. "/secret.txt"
    )
  )
  check(
    "the editor's socket is out of reach, so the canary stays hidden",
    not ((r.stdout or "") .. (r.stderr or "")):find("CANARY"),
    vim.inspect(r)
  )

  r = inside('echo "${FIELDGUIDE_ADDR-unset} ${NVIM-unset}"')
  check("the editor's address is not handed in", vim.trim(r.stdout or "") == "unset unset", r.stdout)

  r = inside(("%q --headless --clean --server %q --remote-expr '1+1'"):format(cfg.paths().nvim_bin, mcp_sock))
  check("the MCP server's socket is the one way to the tools", vim.trim(r.stdout or "") == "2", vim.inspect(r))

  r = inside("ls " .. home)
  check("$HOME cannot be listed", r.code ~= 0 and not (r.stdout or ""):find("%S"), vim.inspect(r))

  -- Seatbelt has no PID namespace; see `agent_seatbelt`.
  if which == "bwrap" then
    r = inside("ps -e -o pid= | wc -l")
    check("only the sandbox's own processes are visible", (tonumber(vim.trim(r.stdout or "")) or 99) < 10, r.stdout)
  end

  -- A doc root inside the config tree — lazy's data kept beside the config —
  -- stays read-only: the longer path is mounted second, and wins.
  local nested = config_dir .. "/vendor-docs"
  vim.fn.mkdir(nested, "p")
  local nested_argv = sandbox._agent_plan(
    which,
    { "sh", "-c", 'eval "$PROBE"' },
    vim.tbl_extend("force", zones, { doc_roots = { doc_root, nested } })
  )
  local env = vim.fn.environ()
  env.PROBE = ("echo x > %q/new.txt; echo $?; echo y > %q/ok.lua; echo $?"):format(nested, config_dir)
  r = vim.system(nested_argv, { env = env, clear_env = true, text = true }):wait(20000)
  check(
    "a doc root nested in the config tree stays read-only",
    vim.split(vim.trim(r.stdout or ""), "\n")[1] ~= "0"
      and vim.split(vim.trim(r.stdout or ""), "\n")[2] == "0"
      and vim.fn.filereadable(nested .. "/new.txt") == 0,
    vim.inspect(r)
  )

  mcp:kill(15)
  server:kill(15)
end

for _, which in ipairs({ "bwrap", "seatbelt" }) do
  local exe = which == "bwrap" and "bwrap" or "sandbox-exec"
  io.write(("agent sandbox: from inside (%s)\n"):format(which))
  if vim.fn.executable(exe) == 0 then
    skipped = skipped + 1
    io.write(("  skip %s is not installed\n"):format(exe))
  else
    from_inside(which)
  end
end

vim.fn.delete(box, "rf")
io.write(("\n%d passed, %d failed%s\n"):format(passed, failed, skipped > 0 and (", " .. skipped .. " skipped") or ""))
os.exit(failed == 0 and 0 or 1)
