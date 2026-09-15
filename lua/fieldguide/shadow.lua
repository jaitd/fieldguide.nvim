-- The shadow repo (§5.11) — undo.
--
-- Separate `--git-dir`, shared `--work-tree`. The plugin never needs to know how
-- the user manages their dotfiles: bare config with no repo, config that *is*
-- the repo, config nested in a larger dotfiles repo — all the same here. And
-- because the work tree is shared there is nothing to merge: when you are
-- happy, the files are already there and the real repo sees ordinary
-- uncommitted changes.
--
-- Linear history with checkpoints, not branches. There is one writer.

local cfg = require("fieldguide.config")

local M = {}

local function git_dir()
  local p = cfg.paths()
  local hash = vim.fn.sha256(p.config_dir):sub(1, 16)
  return p.state_dir .. "/repos/" .. hash
end

---git's directory variables must be *absent*, not empty: an exported but empty
---GIT_WORK_TREE is an error, and an inherited one would silently retarget the
---user's real repo. vim.system can only remove a variable by defining the whole
---environment, so that is what this does.
---
---The process environment doesn't change under us, so compute it once: this
---runs on every git() call, and vim.fn.environ() is not free.
---@return table<string, string>
local cleaned_env
local function clean_env()
  if not cleaned_env then
    cleaned_env = vim.fn.environ()
    for _, key in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY" }) do
      cleaned_env[key] = nil
    end
  end
  return cleaned_env
end

---Always explicit flags per invocation: `git init --bare` refuses to run while
---GIT_WORK_TREE is exported, so the flags are the only reliable channel.
---@param args string[]
---@param opts table?
---@return table
local function git(args, opts)
  opts = opts or {}
  local p = cfg.paths()
  local argv = { "git", "--git-dir=" .. git_dir() }
  if not opts.bare_only then
    table.insert(argv, "--work-tree=" .. p.config_dir)
  end
  vim.list_extend(argv, args)
  local res = vim.system(argv, { cwd = p.config_dir, text = true, env = clean_env(), clear_env = true }):wait(10000)
  return {
    ok = res.code == 0,
    code = res.code,
    stdout = vim.trim(res.stdout or ""),
    stderr = vim.trim(res.stderr or ""),
  }
end

---@return boolean, string?
function M.ensure()
  local dir = git_dir()
  if vim.uv.fs_stat(dir .. "/HEAD") then
    return true
  end
  vim.fn.mkdir(dir, "p")
  local res = vim
    .system({ "git", "init", "--bare", "--quiet", dir }, {
      text = true,
      env = clean_env(),
      clear_env = true,
    })
    :wait(10000)
  if res.code ~= 0 then
    return false, vim.trim(res.stderr or "git init failed")
  end
  -- Identity, so a user with no global git config still gets commits.
  git({ "config", "user.name", "fieldguide" }, { bare_only = true })
  git({ "config", "user.email", "fieldguide@localhost" }, { bare_only = true })
  -- Repack when it gets loose; never prune. A year of this is smaller than one
  -- plugin's doc/ directory, and pruning is the feature you regret the first
  -- time you want to know what the agent did last Tuesday. Said in git's own
  -- config rather than in a startup hook, so it holds for anyone who reaches
  -- this repo with a bare `git` command.
  for key, value in pairs({
    ["gc.auto"] = "256",
    ["gc.pruneExpire"] = "never",
    ["gc.reflogExpire"] = "never",
    ["gc.reflogExpireUnreachable"] = "never",
  }) do
    git({ "config", key, value }, { bare_only = true })
  end
  -- A baseline commit, so the first agent write isn't also the first
  -- commit: without one, HEAD~1 has nothing to land on, and any hand edits
  -- made before the agent's first write get folded into that write's
  -- checkpoint instead of being their own point in history.
  M.checkpoint("baseline")
  return true
end

---Commit the current work tree. Returns the new sha, or nil when nothing
---changed (which is the common case and is not an error). Safe to call
---before a write too — to snapshot a hand edit before the agent overwrites
---it — since an unchanged tree is cheap: one failed `git commit`, not a
---real commit.
---@param label string
---@return table
function M.checkpoint(label)
  local ok, err = M.ensure()
  if not ok then
    return { ok = false, error = err }
  end

  -- Two instances on the same config share one history and can contend on
  -- index.lock. Retry with backoff.
  local add
  for attempt = 1, 5 do
    add = git({ "add", "-A", "." })
    if add.ok or not add.stderr:find("index%.lock") then
      break
    end
    vim.uv.sleep(20 * attempt)
  end
  if not add.ok then
    return { ok = false, error = add.stderr }
  end

  -- Let `commit` itself say whether there was anything to commit, rather
  -- than asking first with a separate `diff --cached`: this also runs as a
  -- pre-write snapshot, so an unchanged tree is the common case, and it now
  -- costs one process instead of two. No --quiet: the summary line is how we
  -- read back the sha below without a separate `rev-parse`.
  local commit = git({ "commit", "-m", label })
  if not commit.ok then
    if commit.stdout:find("nothing to commit") then
      return { ok = true, unchanged = true }
    end
    return { ok = false, error = commit.stderr }
  end

  -- "[branch hash] label" (or "[branch (root-commit) hash] label" for the
  -- first commit) — pull the sha from there. Fall back to rev-parse if a
  -- future git ever changes that format on us.
  local sha = commit.stdout:match("%[.-%s(%x+)%]")
  if not sha then
    sha = git({ "rev-parse", "--short", "HEAD" }).stdout
  end
  local files = git({ "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD" })
  return {
    ok = true,
    sha = sha,
    files = vim.split(files.stdout, "\n", { trimempty = true }),
  }
end

---@param n integer?
---@return table
function M.log(n)
  if not vim.uv.fs_stat(git_dir() .. "/HEAD") then
    return { ok = true, entries = {} }
  end
  local res = git({ "log", "--format=%h\t%ar\t%s", "-n", tostring(n or 20) })
  if not res.ok then
    return { ok = true, entries = {} } -- no commits yet
  end
  local entries = {}
  for line in res.stdout:gmatch("[^\n]+") do
    local sha, when, subject = line:match("^(%S+)\t([^\t]*)\t(.*)$")
    if sha then
      table.insert(entries, { sha = sha, when = when, subject = subject })
    end
  end
  return { ok = true, entries = entries }
end

---Restore the work tree to a checkpoint against the shared work tree — the
---real repo sees this as ordinary uncommitted work.
---@param ref string
---@return table
function M.restore(ref)
  local ok, err = M.ensure()
  if not ok then
    return { ok = false, error = err }
  end

  -- Resolve before snapshotting: the snapshot is itself a commit, so a
  -- relative ref like HEAD~1 resolved after it would end up one commit off.
  local resolved = git({ "rev-parse", "--short", ref })
  if not resolved.ok then
    return { ok = false, error = resolved.stderr }
  end
  local sha = resolved.stdout

  -- Checkpoint first: undoing is itself an edit worth being able to undo.
  M.checkpoint("pre-undo snapshot")

  -- read-tree -u --reset, not `checkout <ref> -- .`: checkout only touches
  -- files present in <ref>, so a file added since would survive the
  -- "restore". -u updates the work tree and --reset the index to match sha
  -- exactly, deleting tracked files sha doesn't have; files untracked in
  -- both trees are never touched, so hand-edited scratch files are safe.
  local res = git({ "read-tree", "-u", "--reset", sha })
  if not res.ok then
    return { ok = false, error = res.stderr }
  end
  return { ok = true, restored = ref, sha = sha }
end

function M.git_dir()
  return git_dir()
end

return M
