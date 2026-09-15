-- Verb: `state` (§5.6). Parameterized and composable; expensive sections opt-in.
--
-- Paths are emitted *relative to the config dir* so that state output and the
-- agent's file tools speak the same language.

local cfg = require("fieldguide.config")
local util = require("fieldguide.util")

local M = {}

M.sections = { "nvim", "buffers", "diagnostics", "plugins", "keymaps", "windows", "lsp", "messages" }

---Resolved git revision of a checkout, without shelling out to git.
---@param dir string
---@return string?
local function git_rev(dir)
  local head = util.read_file(dir .. "/.git/HEAD")
  if not head then
    return nil
  end
  head = vim.trim(head)
  local ref = head:match("^ref:%s*(.+)$")
  if not ref then
    return head -- detached: HEAD is the sha, which is the normal lazy.nvim state
  end
  local sha = util.read_file(dir .. "/.git/" .. ref)
  if sha then
    return vim.trim(sha)
  end
  local packed = util.read_file(dir .. "/.git/packed-refs")
  if packed then
    for line in packed:gmatch("[^\n]+") do
      local s, name = line:match("^(%x+)%s+(.+)$")
      if name == ref then
        return s
      end
    end
  end
  return nil
end

local collect = {}

function collect.nvim()
  local paths = cfg.paths()
  local v = vim.version()
  return {
    version = string.format("%d.%d.%d", v.major, v.minor, v.patch),
    config_dir = paths.config_dir,
    config_dir_declared = paths.config_dir_declared,
    is_symlinked = paths.config_dir ~= paths.config_dir_declared,
    appname = vim.env.NVIM_APPNAME,
    data_dir = paths.data_dir,
    cwd = vim.uv.cwd(),
  }
end

function collect.buffers()
  local root = cfg.paths().config_dir
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted then
      local name = vim.api.nvim_buf_get_name(buf)
      table.insert(out, {
        bufnr = buf,
        path = name ~= "" and util.relative(util.resolve(name), root) or nil,
        filetype = vim.bo[buf].filetype,
        modified = vim.bo[buf].modified,
        loaded = vim.api.nvim_buf_is_loaded(buf),
        lines = vim.api.nvim_buf_line_count(buf),
      })
    end
  end
  return out
end

---@param args table
function collect.diagnostics(args)
  local root = cfg.paths().config_dir
  local severity_name = { "error", "warn", "info", "hint" }
  local per_file, items = {}, {}

  for _, d in ipairs(vim.diagnostic.get(nil)) do
    local name = vim.api.nvim_buf_get_name(d.bufnr)
    local rel = name ~= "" and util.relative(util.resolve(name), root) or ("buf:" .. d.bufnr)
    per_file[rel] = per_file[rel] or { error = 0, warn = 0, info = 0, hint = 0 }
    local sev = severity_name[d.severity] or "hint"
    per_file[rel][sev] = per_file[rel][sev] + 1
    if args.full then
      table.insert(items, {
        path = rel,
        lnum = d.lnum + 1,
        col = d.col + 1,
        severity = sev,
        message = d.message,
        source = d.source,
      })
    end
  end

  return { counts = per_file, items = args.full and items or nil }
end

function collect.plugins()
  local ok, lazy_cfg = pcall(require, "lazy.core.config")
  if not ok then
    return { manager = "unknown", note = "lazy.nvim not detected" }
  end

  local out = {}
  for name, p in pairs(lazy_cfg.plugins) do
    local meta = p._ or {}
    local reason
    if meta.loaded then
      -- lazy copies the load reason into `_.loaded` (cmd / event / keys / ft /
      -- start / plugin), alongside `source` and `time`.
      local keys = {}
      for k, v in pairs(meta.loaded) do
        if k ~= "time" and k ~= "source" then
          table.insert(keys, k .. "=" .. tostring(v))
        end
      end
      table.sort(keys)
      reason = table.concat(keys, " ")
      if reason == "" then
        reason = meta.loaded.source
      end
    end

    -- Tokens are a budget (principle 5): emit the interesting deviations, not
    -- every field at its default value. The revision is short-form for the same
    -- reason — it is there to make the docs join version-correct, and eight
    -- characters does that.
    local rev = p.dir and git_rev(p.dir) or nil
    -- lazy keys plugins by bare repo name; the index keys them by owner/repo.
    -- The spec's short form (or its url) carries the owner, so pass it along
    -- for nvim_plugins to check against.
    local repo = type(p[1]) == "string" and p[1]:match("^[%w_.-]+/[%w_.-]+$")
      or (type(p.url) == "string" and p.url:match("github%.com[:/]([%w_.-]+/[%w_.-]+)"))
      or nil
    if repo then
      repo = repo:gsub("%.git$", "")
    end
    table.insert(out, {
      name = name,
      repo = repo,
      dir = p.dir,
      loaded = meta.loaded ~= nil,
      lazy = p.lazy == true,
      dep = meta.dep == true or nil,
      not_installed = (meta.installed == false or (p.dir and not vim.uv.fs_stat(p.dir))) or nil,
      disabled = p.enabled == false or nil,
      load_reason = reason,
      load_ms = meta.loaded and meta.loaded.time and math.floor(meta.loaded.time / 1e6 * 100) / 100 or nil,
      rev = rev and rev:sub(1, 8) or nil,
      has_errors = meta.has_errors and true or nil,
    })
  end

  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function collect.keymaps()
  local out = {}
  for _, mode in ipairs({ "n", "v", "x", "i", "o", "t" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      table.insert(out, { mode = mode, lhs = m.lhs, desc = m.desc, rhs = m.rhs })
    end
  end
  return out
end

function collect.windows()
  local root = cfg.paths().config_dir
  local out = { current = vim.api.nvim_get_current_win(), windows = {} }
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local pos = vim.api.nvim_win_get_cursor(win)
    table.insert(out.windows, {
      winid = win,
      bufnr = buf,
      path = name ~= "" and util.relative(util.resolve(name), root) or nil,
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
      cursor = { line = pos[1], col = pos[2] },
    })
  end
  return out
end

function collect.lsp()
  local out = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local buffers = {}
    for buf in pairs(client.attached_buffers or {}) do
      table.insert(buffers, buf)
    end
    table.sort(buffers)
    table.insert(out, {
      id = client.id,
      name = client.name,
      root_dir = client.root_dir,
      attached_buffers = buffers,
      filetypes = client.config and client.config.filetypes or nil,
    })
  end
  return out
end

function collect.messages()
  local ok, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if not ok then
    return {}
  end
  local lines = vim.split(res.output or "", "\n", { trimempty = true })
  -- Tail only; :messages on a long-running session is unbounded.
  local tail = {}
  for i = math.max(1, #lines - 50), #lines do
    table.insert(tail, lines[i])
  end
  return tail
end

---@param args table { what?: string[]|string, full?: boolean }
function M.run(args)
  args = args or {}
  local what = args.what or cfg.options.state.default
  if type(what) == "string" then
    what = vim.split(what, ",", { trimempty = true })
  end

  local out = {}
  for _, name in ipairs(what) do
    name = vim.trim(name)
    local fn = collect[name]
    if not fn then
      out[name] = { error = "unknown section (have: " .. table.concat(M.sections, ", ") .. ")" }
    else
      local ok, res = pcall(fn, args)
      out[name] = ok and res or { error = tostring(res) }
    end
  end
  return out
end

return M
