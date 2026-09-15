-- Shadow repo (§8): the three topologies from §4, lock contention, and undo.
--
--   nvim -l tests/shadow.lua
--
-- The whole point of the shadow is that the plugin never needs to know how the
-- user manages their dotfiles, so the test is mostly "does it not care".

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")
local shadow = require("fieldguide.shadow")
local util = require("fieldguide.util")

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

local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  vim.uv.fs_write(fd, text)
  vim.uv.fs_close(fd)
end

local function git(dir, args)
  return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait(10000)
end

---Point fieldguide at a fresh config dir and clean up its shadow afterwards.
---@param name string
---@param build fun(dir: string)
---@param body fun(dir: string)
local function topology(name, build, body)
  local dir = scratch .. "/" .. name
  vim.fn.mkdir(dir, "p")
  build(dir)
  cfg.setup({ cwd = dir })
  local ok, err = pcall(body, dir)
  if not ok then
    check(name .. ": raised", false, tostring(err))
  end
  vim.fn.delete(shadow.git_dir(), "rf")
end

io.write("shadow repo topologies\n")

-- 1. A bare nvim config with no repo at all.
topology("no-repo", function(dir)
  write(dir .. "/init.lua", "-- v1\n")
end, function(dir)
  local ok = shadow.ensure()
  check("no repo: ensure succeeds", ok == true, tostring(ok))
  local baseline = shadow.log(10)
  check(
    "no repo: a baseline checkpoint exists after ensure()",
    #baseline.entries == 1 and baseline.entries[1].subject == "baseline",
    vim.inspect(baseline)
  )

  write(dir .. "/init.lua", "-- v2\n")
  local c = shadow.checkpoint("first")
  check("no repo: checkpoint commits", c.ok and c.sha ~= nil, vim.inspect(c))
  check("no repo: the config dir stays repo-less", vim.uv.fs_stat(dir .. "/.git") == nil, "a .git appeared")
  local again = shadow.checkpoint("nothing changed")
  check("no repo: an unchanged tree is not a new commit", again.unchanged == true, vim.inspect(again))
end)

-- 2. The config dir *is* a git repo.
topology("is-repo", function(dir)
  write(dir .. "/init.lua", "-- v1\n")
  git(dir, { "init", "--quiet" })
  git(dir, { "config", "user.email", "t@t" })
  git(dir, { "config", "user.name", "t" })
  git(dir, { "add", "-A" })
  git(dir, { "commit", "--quiet", "-m", "real history" })
end, function(dir)
  shadow.ensure() -- baseline picks up v1, so the edit below is its own commit
  local before = git(dir, { "rev-list", "--count", "HEAD" }).stdout
  write(dir .. "/init.lua", "-- v2\n")
  local c = shadow.checkpoint("agent write")
  check("own repo: checkpoint commits", c.ok and c.sha ~= nil, vim.inspect(c))

  local after = git(dir, { "rev-list", "--count", "HEAD" }).stdout
  check("own repo: the real history is untouched", before == after, before .. " -> " .. after)

  -- Because the work tree is shared, there is nothing to merge: the real repo
  -- sees the change as ordinary uncommitted work.
  local status = git(dir, { "status", "--porcelain" }).stdout
  check("own repo: the real repo sees ordinary uncommitted changes", status:find("init.lua") ~= nil, status)
end)

-- 3. The config dir nested inside a much larger dotfiles repo — the common case
--    §4 says cannot be assumed away.
topology("nested", function(dir)
  local config = dir .. "/nvim/.config/nvim"
  write(config .. "/init.lua", "-- v1\n")
  write(dir .. "/zsh/.zshrc", "export SECRET=1\n")
  git(dir, { "init", "--quiet" })
  git(dir, { "config", "user.email", "t@t" })
  git(dir, { "config", "user.name", "t" })
  git(dir, { "add", "-A" })
  git(dir, { "commit", "--quiet", "-m", "dotfiles" })
end, function(dir)
  local config = dir .. "/nvim/.config/nvim"
  cfg.setup({ cwd = config })
  shadow.ensure() -- baseline picks up v1, so the edit below is its own commit
  write(config .. "/init.lua", "-- v2\n")
  local c = shadow.checkpoint("agent write")
  check("nested: checkpoint commits", c.ok and c.sha ~= nil, vim.inspect(c))
  check(
    "nested: only the config subtree is tracked",
    not vim.tbl_contains(c.files or {}, "zsh/.zshrc"),
    vim.inspect(c.files)
  )
  local outer = git(dir, { "rev-list", "--count", "HEAD" }).stdout
  check("nested: the outer repo's history is untouched", vim.trim(outer) == "1", outer)
end)

io.write("undo\n")
topology("undo", function(dir)
  write(dir .. "/init.lua", "-- v1\n")
end, function(dir)
  shadow.checkpoint("v1") -- folds into the baseline: nothing has changed yet
  write(dir .. "/init.lua", "-- v2\n")
  shadow.checkpoint("v2")

  local res = shadow.restore("HEAD~1")
  check("undo: reports success", res.ok == true, vim.inspect(res))
  check(
    "undo: reports the resolved sha alongside the ref",
    type(res.sha) == "string" and #res.sha > 0,
    vim.inspect(res)
  )
  check(
    "undo: restores the known state",
    util.read_file(dir .. "/init.lua") == "-- v1\n",
    util.read_file(dir .. "/init.lua")
  )

  local log = shadow.log(10)
  check("undo: history is linear and kept", #log.entries >= 2, vim.inspect(log))
end)

-- A single agent write, undone: the common case the command exists for.
topology("undo-single-write", function(dir)
  write(dir .. "/init.lua", "-- hand-written v1\n")
end, function(dir)
  shadow.ensure() -- baseline captures the pre-write file
  write(dir .. "/init.lua", "-- agent overwrote it\n")
  local c = shadow.checkpoint("agent write")
  check("undo-single-write: checkpoint commits", c.ok and c.sha ~= nil, vim.inspect(c))

  local res = shadow.restore("HEAD~1")
  check("undo-single-write: restore succeeds", res.ok == true, vim.inspect(res))
  check(
    "undo-single-write: restores the pre-write file",
    util.read_file(dir .. "/init.lua") == "-- hand-written v1\n",
    util.read_file(dir .. "/init.lua")
  )
end)

-- A file created after the checkpoint being restored to must not survive:
-- `checkout <ref> -- .` would have left it behind.
topology("undo-removes-added-file", function(dir)
  write(dir .. "/init.lua", "-- v1\n")
end, function(dir)
  shadow.ensure() -- baseline: init.lua only

  write(dir .. "/new.lua", "-- added after the checkpoint\n")
  local c = shadow.checkpoint("added new.lua")
  check("undo-removes-added-file: checkpoint commits", c.ok and c.sha ~= nil, vim.inspect(c))
  check("undo-removes-added-file: new.lua exists before restore", vim.uv.fs_stat(dir .. "/new.lua") ~= nil, "missing")

  local res = shadow.restore("HEAD~1")
  check("undo-removes-added-file: restore succeeds", res.ok == true, vim.inspect(res))
  check(
    "undo-removes-added-file: a file absent from the target ref is removed",
    vim.uv.fs_stat(dir .. "/new.lua") == nil,
    "new.lua still exists"
  )
end)

-- A hand edit between two agent writes must land its own checkpoint, and
-- undo must be able to reach exactly it via HEAD~1.
topology("undo-hand-edit", function(dir)
  write(dir .. "/init.lua", "-- v1\n")
end, function(dir)
  shadow.ensure() -- baseline: v1

  write(dir .. "/init.lua", "-- v2 agent\n")
  shadow.checkpoint("agent write 1")

  -- A pre-write snapshot (as the extension takes before its own writes)
  -- captures the hand edit as its own point in history.
  write(dir .. "/init.lua", "-- v3 by hand\n")
  shadow.checkpoint("pre-write snapshot")

  write(dir .. "/init.lua", "-- v4 agent\n")
  shadow.checkpoint("agent write 2")

  local res = shadow.restore("HEAD~1")
  check("undo-hand-edit: restore succeeds", res.ok == true, vim.inspect(res))
  check(
    "undo-hand-edit: HEAD~1 lands on the hand edit, not folded into the next checkpoint",
    util.read_file(dir .. "/init.lua") == "-- v3 by hand\n",
    util.read_file(dir .. "/init.lua")
  )
end)

io.write("lock contention\n")
topology("lock", function(dir)
  write(dir .. "/init.lua", "-- v1\n")
end, function(dir)
  shadow.ensure()
  write(shadow.git_dir() .. "/index.lock", "")
  write(dir .. "/init.lua", "-- v2\n")

  local t0 = vim.uv.hrtime()
  local c = shadow.checkpoint("contended")
  local elapsed = (vim.uv.hrtime() - t0) / 1e6

  -- Retry with backoff, then give up with something readable. Never hang, and
  -- never silently drop the write.
  check("lock: a held lock fails rather than hanging", c.ok == false, vim.inspect(c))
  check("lock: gives up in bounded time", elapsed < 5000, ("%.0fms"):format(elapsed))
  check("lock: the error names the lock", (c.error or ""):find("index%.lock") ~= nil, tostring(c.error))
end)

vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
