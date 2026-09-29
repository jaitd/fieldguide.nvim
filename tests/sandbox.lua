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
-- canary beside them that must not exist from inside.
local box = util.resolve(vim.fn.tempname())
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

io.write("agent sandbox: seatbelt profile\n")
do
  local argv = sandbox._agent_plan("seatbelt", { "harness" }, zones)
  local profile = argv[3] or ""
  check("inline profile, no file to clean up", argv[1] == "sandbox-exec" and argv[2] == "-p", table.concat(argv, " "))
  check(
    "reads of $HOME are denied",
    profile:find('(deny file-read* (subpath "' .. home .. '"))', 1, true) ~= nil,
    profile
  )
  check("writes are denied by default", profile:find("(deny file-write*)", 1, true) ~= nil, profile)
  check("the config tree is readable", profile:find('(subpath "' .. config_dir .. '")', 1, true) ~= nil, profile)
  local writes = profile:match("%(deny file%-write%*%)(.*)$") or ""
  check("the doc root is not writable", not writes:find(doc_root, 1, true), profile)
  check("the network is not denied", not profile:find("deny network", 1, true), profile)
end

io.write("agent sandbox: from inside (bwrap)\n")
if vim.fn.executable("bwrap") == 0 then
  skipped = skipped + 1
  io.write("  skip bwrap is not installed\n")
else
  -- A live editor for the socket, with fieldguide loaded, as the MCP server
  -- would find it.
  local sock = box .. "/nvim.sock"
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
  vim.wait(5000, function()
    return vim.uv.fs_stat(sock) ~= nil
  end, 50)

  local argv =
    sandbox._agent_plan("bwrap", { "sh", "-c", 'eval "$PROBE"' }, vim.tbl_extend("force", zones, { socket = sock }))

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
  check("the doc root cannot be written", r.code ~= 0 and (r.stderr or ""):find("Read%-only") ~= nil, r.stderr)

  r = inside("echo written > " .. config_dir .. "/new.lua && cat " .. config_dir .. "/new.lua")
  check("the config tree can be written", r.code == 0 and vim.trim(r.stdout or "") == "written", vim.inspect(r))
  check("and the write is real, outside", vim.fn.filereadable(config_dir .. "/new.lua") == 1)

  r = inside("cat " .. doc_root .. "/fixture.txt")
  check("the doc root can be read", r.code == 0 and (r.stdout or ""):find("fixture") ~= nil, vim.inspect(r))

  -- The whole tool path: the CLI the MCP server calls, through the socket. By
  -- absolute path: a PATH entry under $HOME, such as ~/.local/bin, is gone in
  -- here unless something binds it back, and the install prefix is what is.
  r = inside(("%q -l %q state --what=nvim"):format(cfg.paths().nvim_bin, root .. "/bin/fieldguide"))
  local ok_json, decoded = pcall(vim.json.decode, r.stdout or "")
  check(
    "the editor is reachable over the bound socket",
    r.code == 0 and ok_json and decoded.ok ~= false,
    vim.inspect(r)
  )

  r = inside("ps -e -o pid= | wc -l")
  check("only the sandbox's own processes are visible", (tonumber(vim.trim(r.stdout or "")) or 99) < 10, r.stdout)

  server:kill(15)
end

vim.fn.delete(box, "rf")
io.write(("\n%d passed, %d failed%s\n"):format(passed, failed, skipped > 0 and (", " .. skipped .. " skipped") or ""))
os.exit(failed == 0 and 0 or 1)
