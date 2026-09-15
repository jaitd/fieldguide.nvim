-- verify fixtures (§8). Run headlessly, no test framework beyond `assert`:
--
--   nvim -l tests/verify.lua
--
-- Each fixture is pointed at with cfg.setup({ cwd = … }), which is the only
-- supported way to retarget verify — the verb itself takes no directory.

-- ":p" first: invoked as `nvim -l tests/verify.lua` the source is relative, and
-- a relative path reaches bwrap as a mount source it cannot resolve.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")
local verify = require("fieldguide.verify")

local passed, failed = 0, 0

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.write(("  ok   %s\n"):format(name))
  else
    failed = failed + 1
    io.write(("  FAIL %s\n       %s\n"):format(name, detail or ""))
  end
end

---@param fixture string
---@param opts table?
local function run(fixture, opts)
  cfg.setup({ cwd = root .. "/tests/fixtures/" .. fixture, verify = opts or {} })
  verify.last = nil -- each fixture starts without a diff baseline
  return verify.run({})
end

local function joined(list)
  return table.concat(list or {}, " | ")
end

io.write("verify fixtures\n")

-- 1. A clean config boots and says so.
do
  local r = run("clean")
  check("clean: ok", r.ok == true, joined(r.errors) .. " " .. tostring(r.error))
  check("clean: no errors", #(r.errors or {}) == 0, joined(r.errors))
  check("clean: reports a duration", type(r.duration_ms) == "number" and r.duration_ms > 0, tostring(r.duration_ms))
  check("clean: no escape alarms", r.escape_alarms == nil, vim.inspect(r.escape_alarms))
end

-- 2. A syntax error is reported, not thrown.
do
  local r = run("syntax-error")
  check("syntax error: not ok", r.ok == false, "reported ok")
  check("syntax error: has an error line", #(r.errors or {}) > 0, joined(r.errors))
end

-- 3. A runtime error at startup surfaces with its message.
do
  local r = run("runtime-error")
  check("runtime error: not ok", r.ok == false, "reported ok")
  check("runtime error: mentions the nil index", joined(r.errors):lower():find("nil") ~= nil, joined(r.errors))
end

-- 4. A spec naming an uninstalled plugin reports "would install", and does not
--    reach the network to find out.
do
  local r = run("missing-plugin")
  local would = r.plugins and r.plugins.would_install or {}
  check("missing plugin: named in would_install", #would > 0, vim.inspect(r.plugins))
  check("missing plugin: note says it was not verified", (r.note or ""):find("not verified") ~= nil, tostring(r.note))
end

-- 5. A hanging boot is killed and reported as a timeout, not left to wedge the
--    sidebar.
do
  local r = run("hangs", { timeout_ms = 1500 })
  check("hangs: reported as a timeout", r.timed_out == true or r.ok == false, vim.inspect(r))
end

-- 6. THE DOCUMENTATION TEST (§6). Deferred payloads do not execute under a
--    verify boot, so verify reports clean. It is a correctness control. Never a
--    security one. If this test ever starts failing because the payloads ran,
--    that is a change in nvim's behaviour, not a fix.
do
  local r = run("deferred-payload")
  check("payload fixture: verify reports a clean boot", r.ok == true, joined(r.errors))
  local msgs = joined(r.messages)
  check(
    "payload fixture: no payload executed (this is the limit, not the feature)",
    msgs:find("FIELDGUIDE_PAYLOAD_EXECUTED") == nil,
    msgs
  )
end

-- 7. The sandbox is real. Whichever backend this machine has, a config that
--    tries to write outside itself and to reach the network gets neither, and
--    the attempt shows up as an alarm rather than being silently swallowed.
do
  local marker = vim.fn.expand("~/.fieldguide-escape-test")
  vim.fn.delete(marker)
  local r = run("escapes")
  check(("escapes: ran under a sandbox (%s)"):format(tostring(r.sandbox)), r.sandbox ~= nil, tostring(r.error))
  check("escapes: the write never reached the host", vim.uv.fs_stat(marker) == nil, marker .. " exists")
  if vim.fn.executable("curl") == 1 then
    local kinds = {}
    for _, a in ipairs(r.escape_alarms or {}) do
      kinds[a.kind] = true
    end
    check("escapes: the network attempt raised an alarm", kinds.network == true, vim.inspect(r.escape_alarms))
    check(
      "escapes: the alarm is not a verdict — the boot still reports its result",
      r.escape_alarm_note ~= nil and r.errors ~= nil,
      vim.inspect(r)
    )
  end
  vim.fn.delete(marker)
end

-- 8. The structured diff against the previous run.
do
  cfg.setup({ cwd = root .. "/tests/fixtures/clean" })
  verify.last = nil
  local first = verify.run({})
  check("diff: absent on the first run", first.diff == nil, vim.inspect(first.diff))
  local second = verify.run({})
  check("diff: present on the second run", second.diff ~= nil, "no diff")
  check(
    "diff: unchanged config reports unchanged",
    second.diff and second.diff.unchanged == true,
    vim.inspect(second.diff)
  )
end

-- 9. bwrap plan construction (no bwrap needed — this only inspects the argv
--    it would build). A stow-style config symlinks file by file out to a
--    dotfiles tree; the plan must --ro-bind the tree the links resolve to,
--    not just the config dir itself, placed after the $HOME tmpfs so it is
--    not masked, and not doubled up when two links point at the same place.
do
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/config", "p")
  vim.fn.mkdir(base .. "/dotfiles/nvim", "p")
  vim.fn.writefile({ "-- fixture" }, base .. "/dotfiles/nvim/init.lua")
  vim.fn.writefile({ "-- fixture" }, base .. "/dotfiles/nvim/other.lua")
  vim.uv.fs_symlink(base .. "/dotfiles/nvim/init.lua", base .. "/config/init.lua")
  vim.uv.fs_symlink(base .. "/dotfiles/nvim/other.lua", base .. "/config/other.lua")
  local config_dir = vim.uv.fs_realpath(base .. "/config")
  local target = vim.uv.fs_realpath(base .. "/dotfiles/nvim")

  cfg.setup({ cwd = config_dir })
  local plan = verify._plan("bwrap", config_dir)

  local home_idx, target_idx, target_count = nil, nil, 0
  for i, v in ipairs(plan.argv) do
    if v == cfg.paths().home and plan.argv[i - 1] == "--tmpfs" then
      home_idx = i
    end
    if v == target then
      target_count = target_count + 1
      target_idx = target_idx or i
    end
  end

  check("bwrap plan: binds the symlink target", target_idx ~= nil, table.concat(plan.argv, " "))
  check(
    "bwrap plan: after the $HOME tmpfs so it is not masked",
    home_idx ~= nil and target_idx ~= nil and target_idx > home_idx,
    table.concat(plan.argv, " ")
  )
  check("bwrap plan: bound once, not once per symlink", target_count == 2, table.concat(plan.argv, " "))

  cfg.setup({})
  vim.fn.delete(base, "rf")
end

-- 10. plan + interpret round-trip to the same result M.run gives — the split
--     that lets the CLI own the spawn must not change what comes out the
--     other end.
do
  cfg.setup({ cwd = root .. "/tests/fixtures/clean" })
  verify.last = nil
  local direct = verify.run({})

  cfg.setup({ cwd = root .. "/tests/fixtures/clean" })
  verify.last = nil
  local plan = verify.plan({})
  check("plan: ok", plan.ok == true, vim.inspect(plan))
  check("plan: has an argv", type(plan.argv) == "table" and #plan.argv > 0, vim.inspect(plan))
  check("plan: names a sandbox backend", plan.sandbox ~= nil, vim.inspect(plan))

  local t0 = vim.uv.hrtime()
  local proc = vim.system(plan.argv, { cwd = plan.cwd, env = plan.env, clear_env = true, text = true })
  local res = proc:wait(plan.timeout_ms)
  local duration_ms = math.floor((vim.uv.hrtime() - t0) / 1e4) / 100
  verify.cleanup(plan)

  local via_split =
    verify.interpret(res, { duration_ms = duration_ms, timeout_ms = plan.timeout_ms, sandbox = plan.sandbox })

  check("plan+interpret: ok matches run", via_split.ok == direct.ok, vim.inspect({ via_split, direct }))
  check(
    "plan+interpret: errors match run",
    joined(via_split.errors) == joined(direct.errors),
    vim.inspect({ via_split.errors, direct.errors })
  )
  check(
    "plan+interpret: plugin summary matches run",
    vim.deep_equal(via_split.plugins, direct.plugins),
    vim.inspect({ via_split.plugins, direct.plugins })
  )
end

-- 11. interpret on a synthetic timed-out result — no sandbox involved, just
--     the classification logic.
do
  verify.last = nil
  local r = verify.interpret(
    { code = 124, signal = nil, stdout = "", stderr = "" },
    { duration_ms = 1500, timeout_ms = 1500 }
  )
  check("interpret: code 124 is a timeout", r.timed_out == true, vim.inspect(r))
  check("interpret: timeout is not ok", r.ok == false, vim.inspect(r))

  verify.last = nil
  local r2 = verify.interpret(
    { code = nil, signal = 15, stdout = "", stderr = "" },
    { duration_ms = 2000, timeout_ms = 1500 }
  )
  check("interpret: SIGTERM past the deadline is also a timeout", r2.timed_out == true, vim.inspect(r2))
end

-- 12. interpret on a synthetic "sandbox never started" result — the bwrap/
--     seatbelt-prefixed stderr line, not a config that failed to boot.
do
  verify.last = nil
  local r = verify.interpret(
    { code = 1, signal = nil, stdout = "", stderr = "bwrap: execvp bwrap: No such file or directory\n" },
    { duration_ms = 10, timeout_ms = 1500, sandbox = "bwrap" }
  )
  check("interpret: bwrap never-started reports not ok", r.ok == false, vim.inspect(r))
  check(
    "interpret: bwrap never-started says the sandbox failed to start",
    (r.error or ""):find("sandbox failed to start") ~= nil,
    tostring(r.error)
  )
  check("interpret: bwrap never-started is not mistaken for an escape alarm", r.escape_alarms == nil, vim.inspect(r))

  verify.last = nil
  local r2 = verify.interpret(
    { code = 1, signal = nil, stdout = "", stderr = "sandbox-exec: execvp sandbox-exec: No such file or directory\n" },
    { duration_ms = 10, timeout_ms = 1500, sandbox = "seatbelt" }
  )
  check("interpret: seatbelt never-started reports not ok", r2.ok == false, vim.inspect(r2))
  check(
    "interpret: seatbelt never-started says the sandbox failed to start",
    (r2.error or ""):find("sandbox failed to start") ~= nil,
    tostring(r2.error)
  )
end

cfg.setup({})

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
