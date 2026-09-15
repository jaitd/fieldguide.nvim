-- Verb: `docs` — the resolver. The differentiated piece.
--
-- Resolution only. Retrieval is `read`/`grep` on the doc zone, or the opt-in
-- `fetch` slice below. Scoped to *installed* plugins at their *resolved
-- revisions*: the answer matches what is on disk, which is the entire moat.
--
-- Every documented plugin ships a `doc/tags` index (tab-separated
-- `tag <TAB> file <TAB> pattern`), so this is a parser, not a search problem.

local cfg = require("fieldguide.config")
local util = require("fieldguide.util")

local M = {}

local MAX_MATCHES = 25

---@return table[] { name, dir, rev }
local function installed_plugins()
  local ok, lazy_cfg = pcall(require, "lazy.core.config")
  if not ok then
    return {}
  end
  local out = {}
  for name, p in pairs(lazy_cfg.plugins) do
    if p.dir and vim.uv.fs_stat(p.dir) then
      table.insert(out, { name = name, dir = p.dir, url = p.url })
    end
  end
  return out
end

---Parse one `doc/tags` file into { tag -> { file, pattern } }.
---@param tags_path string
---@return table<string, string>
local function parse_tags(tags_path)
  local data = util.read_file(tags_path)
  if not data then
    return {}
  end
  local out = {}
  for line in data:gmatch("[^\n]+") do
    local tag, file = line:match("^([^\t]+)\t([^\t]+)\t")
    if tag and file then
      out[tag] = file
    end
  end
  return out
end

---The whole corpus: every installed plugin's tags plus $VIMRUNTIME's.
---Rebuilt per call — 30-odd small files, and staleness here would be a lie
---about what is installed. A caller resolving several queries in one go (e.g.
---`explain_keymap` walking every owning plugin) should build it once with
---`M.corpus()` and pass it back in via `args.corpus`, rather than pay for it
---N times over — that is amortizing one call's work, not a persistent cache.
---@return table[] sources { owner, doc_dir, tags: table }
local function corpus()
  local sources = {}

  for _, p in ipairs(installed_plugins()) do
    local doc_dir = p.dir .. "/doc"
    if vim.uv.fs_stat(doc_dir .. "/tags") then
      table.insert(sources, { owner = p.name, dir = p.dir, doc_dir = doc_dir, tags = parse_tags(doc_dir .. "/tags") })
    else
      table.insert(sources, { owner = p.name, dir = p.dir, doc_dir = nil, tags = {} })
    end
  end

  local runtime = cfg.paths().runtime
  if runtime and vim.uv.fs_stat(runtime .. "/doc/tags") then
    table.insert(sources, {
      owner = "$VIMRUNTIME",
      dir = runtime,
      doc_dir = runtime .. "/doc",
      tags = parse_tags(runtime .. "/doc/tags"),
    })
  end

  return sources
end

---Public entry point onto `corpus()`, for a caller that is about to run
---several `M.run` queries and wants to build the corpus once and reuse it —
---see the note on `corpus` above.
---@return table[] sources
function M.corpus()
  return corpus()
end

---Line number of `*tag*` inside a help file. The tags index stores a search
---pattern, not an anchor; the agent wants a number it can pass to `read`.
---@param path string
---@param tag string
---@return integer?
local function anchor(path, tag)
  local data = util.read_file(path)
  if not data then
    return nil
  end
  local needle = "*" .. tag .. "*"
  local lnum = 1
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    if line:find(needle, 1, true) then
      return lnum
    end
    lnum = lnum + 1
  end
  return nil
end

---Doc-less plugins resolve to their README, and the result says so rather than
---returning empty.
---@param dir string
---@return string?
local function readme(dir)
  for _, name in ipairs({ "README.md", "readme.md", "README.markdown", "README", "README.rst" }) do
    if vim.uv.fs_stat(dir .. "/" .. name) then
      return dir .. "/" .. name
    end
  end
  return nil
end

---@param query string
---@param src table
---@return table[]
local function tag_matches(query, src)
  local exact, partial = {}, {}
  local lower = query:lower()
  for tag, file in pairs(src.tags) do
    if tag == query then
      table.insert(exact, { tag = tag, file = file })
    elseif tag:lower():find(lower, 1, true) then
      table.insert(partial, { tag = tag, file = file })
    end
  end
  return exact, partial
end

---Everything a `docs` result carries about one hit.
local function hit(src, tag, file)
  local path = src.doc_dir .. "/" .. file
  return {
    tag = tag,
    plugin = src.owner,
    path = path,
    line = anchor(path, tag),
    kind = "helptag",
  }
end

---@param args table { query: string, fetch?: boolean, lines?: integer, corpus?: table[] }
function M.run(args)
  args = args or {}
  local query = args.query and vim.trim(args.query) or ""
  if query == "" then
    return { error = "docs requires a `query`: a helptag, or a plugin name" }
  end

  local sources = args.corpus or corpus()
  local by_name = {}
  for _, s in ipairs(sources) do
    by_name[s.owner] = s
  end

  local exact, partial, plugin_hits = {}, {}, {}

  -- 1. helptag, exact then substring
  for _, src in ipairs(sources) do
    if src.doc_dir then
      local e, p = tag_matches(query, src)
      for _, m in ipairs(e) do
        table.insert(exact, hit(src, m.tag, m.file))
      end
      for _, m in ipairs(p) do
        table.insert(partial, { src = src, tag = m.tag, file = m.file })
      end
    end
  end

  -- 2. plugin name. Matched loosely: "fugitive" should find "vim-fugitive".
  local lower = query:lower():gsub("%.nvim$", ""):gsub("^nvim%-", ""):gsub("^vim%-", "")
  for _, src in ipairs(sources) do
    local owner = src.owner:lower()
    if owner == query:lower() or (lower ~= "" and owner:find(lower, 1, true)) then
      local entry = { plugin = src.owner, dir = src.dir, kind = "plugin" }
      if src.doc_dir then
        entry.doc_dir = src.doc_dir
        entry.doc_files = {}
        local fd = vim.uv.fs_scandir(src.doc_dir)
        while fd do
          local name, t = vim.uv.fs_scandir_next(fd)
          if not name then
            break
          end
          if t ~= "directory" and name:match("%.txt$") then
            table.insert(entry.doc_files, src.doc_dir .. "/" .. name)
          end
        end
        table.sort(entry.doc_files)
        entry.tag_count = vim.tbl_count(src.tags)
      else
        entry.path = readme(src.dir)
        entry.note = entry.path and "ships no doc/ — README only"
          or "ships no doc/ and no README; read the source under `dir`"
      end
      table.insert(plugin_hits, entry)
    end
  end

  -- Truncate the fuzzy tier only; exact hits and plugin hits are always small.
  local partial_hits, truncated = {}, false
  for i, m in ipairs(partial) do
    if i > MAX_MATCHES then
      truncated = true
      break
    end
    table.insert(partial_hits, hit(m.src, m.tag, m.file))
  end

  local result = {
    query = query,
    exact = exact,
    plugins = plugin_hits,
    partial = partial_hits,
    partial_truncated = truncated and (#partial - #partial_hits) or nil,
  }

  if #exact == 0 and #plugin_hits == 0 and #partial_hits == 0 then
    result.note = ("nothing installed matches %q. It is not installed here — say so rather than "):format(query)
      .. "answering from a different version."
    result.installed = vim.tbl_map(function(s)
      return s.owner
    end, sources)
  end

  -- Companion fetch: raw .txt slice by tag anchor. Not nvim-rendered help —
  -- the rendering is cosmetic and the token cost is not.
  --
  -- Falls back through the same ladder the resolver reports, so a plugin whose
  -- name is not itself a helptag (most of them) still returns text rather than
  -- silently nothing.
  if args.fetch then
    local lines = args.lines or 60
    if #exact > 0 then
      result.slice = M.slice(exact[1].path, exact[1].line or 1, lines)
    elseif #plugin_hits > 0 then
      local first = plugin_hits[1]
      local path = first.doc_files and first.doc_files[1] or first.path
      if path then
        result.slice = M.slice(path, 1, lines)
      end
    elseif #partial_hits > 0 then
      result.slice = M.slice(partial_hits[1].path, partial_hits[1].line or 1, lines)
    end
  end

  return result
end

---@param path string
---@param from integer
---@param count integer
function M.slice(path, from, count)
  local data = util.read_file(path)
  if not data then
    return { error = "cannot read " .. path }
  end
  local lines = vim.split(data, "\n")
  local out = {}
  for i = from, math.min(#lines, from + count - 1) do
    table.insert(out, lines[i])
  end
  return { path = path, from = from, to = math.min(#lines, from + count - 1), text = table.concat(out, "\n") }
end

return M
