-- Verb: `explain_keymap` — the join, shipped as one verb rather than
-- three the agent has to assemble.
--
-- `nvim_get_keymap` has no source location; `:verbose map` does. Keymap
-- provenance points at a plugin; the plugin points at its docs. That chain is
-- the feature.

local cfg = require("fieldguide.config")
local docs = require("fieldguide.docs")
local util = require("fieldguide.util")

local M = {}

local MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }

---@param lhs string
---@return string
local function normalize(lhs)
  -- `<leader>gs` as typed by a human; nvim_get_keymap reports it expanded.
  local ok, res = pcall(vim.api.nvim_replace_termcodes, lhs, true, true, true)
  return ok and res or lhs
end

---Which installed plugin owns this path, if any.
---@param path string
---@return string?, string?
local function owner_of(path)
  local ok, lazy_cfg = pcall(require, "lazy.core.config")
  if not ok then
    return nil
  end
  local resolved = util.resolve(path)
  for name, p in pairs(lazy_cfg.plugins) do
    if p.dir and util.is_under(resolved, util.resolve(p.dir)) then
      return name, p.dir
    end
  end
  return nil
end

---`:verbose {mode}map <lhs>` lists every mapping whose lhs has <lhs> as a
---*prefix* — `gc` pulls in `gcc` — one block per mapping, each starting at
---column 0 with its own lhs and continuing on indented lines. Split on that
---so the caller can pick the one block that is actually the mapping asked
---for, instead of the first "Last set from" in the whole listing.
---@param out string
---@return table[] { lhs: string, text: string }
local function verbose_map_blocks(out)
  local blocks = {}
  local current
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%S") then
      current = { lhs = line:match("^%S+%s+(%S+)"), lines = { line } }
      table.insert(blocks, current)
    elseif current then
      table.insert(current.lines, line)
    end
  end
  for _, b in ipairs(blocks) do
    b.text = table.concat(b.lines, "\n")
    b.lines = nil
  end
  return blocks
end

---Parse `:verbose map` output for the "Last set from" trailer, scoped to the
---one block whose own lhs is the one that was asked for.
---@param mode string
---@param lhs string
---@return table?
local function definition_site(mode, lhs)
  -- `nvim_get_keymap` reports lhs with the leader expanded, so a space-leader
  -- mapping comes back as " gs" — which `:verbose nmap  gs` collapses into
  -- nothing. keytrans() turns it back into the `<Space>gs` the command parser
  -- actually understands.
  local ok_kt, translated = pcall(vim.fn.keytrans, lhs)
  local escaped = (ok_kt and translated or lhs):gsub("|", "<Bar>")
  local ok, res = pcall(vim.api.nvim_exec2, ("verbose %smap %s"):format(mode, escaped), { output = true })
  if not ok then
    return nil
  end
  local out = res.output or ""

  local want = ok_kt and translated or lhs
  local block
  for _, b in ipairs(verbose_map_blocks(out)) do
    if b.lhs == want or b.lhs == lhs then
      block = b
      break
    end
  end
  local text = block and block.text or out

  local file, line = text:match("Last set from (.-) line (%d+)")
  if not file then
    -- Without `-V1` there is no line number and the trailer carries a
    -- parenthetical instead ("(run Nvim with -V1 for more details)"); strip
    -- it rather than folding it into the path.
    file = text:match("Last set from (.-)%s*%(run Nvim")
  end
  if not file then
    file = text:match("Last set from (.+)")
  end
  if not file then
    return { raw = vim.trim(text) }
  end
  file = vim.trim(file)
  local expanded = vim.fn.expand(file)
  local plugin, plugin_dir = owner_of(expanded)
  return {
    file = expanded,
    line = line and tonumber(line) or nil,
    plugin = plugin,
    plugin_dir = plugin_dir,
    in_config = util.is_under(util.resolve(expanded), cfg.paths().config_dir),
    raw = vim.trim(text),
  }
end

---lazy.nvim caches every `keys = {...}` spec entry, including for plugins that
---have not loaded yet. That is how a lhs with no live mapping still resolves to
---an owner — the common "why didn't my keymap take" case.
---@param lhs string
---@return table[]
local function lazy_key_specs(lhs)
  local ok, lazy_cfg = pcall(require, "lazy.core.config")
  if not ok then
    return {}
  end
  local out = {}
  for name, p in pairs(lazy_cfg.plugins) do
    local cache = p._ and p._.cache or {}
    for _, k in ipairs(cache.keys_list or {}) do
      local spec_lhs = type(k) == "table" and (k[1] or k.lhs) or k
      if type(spec_lhs) == "string" and normalize(spec_lhs) == lhs then
        table.insert(out, {
          plugin = name,
          lhs = spec_lhs,
          mode = type(k) == "table" and k.mode or nil,
          desc = type(k) == "table" and k.desc or nil,
          rhs = type(k) == "table" and (type(k[2]) == "string" and k[2] or "<function>") or nil,
          loaded = p._ and p._.loaded ~= nil,
        })
      end
    end
  end
  return out
end

---@param args table { lhs: string, mode?: string }
function M.run(args)
  args = args or {}
  -- Deliberately not trimmed: with a space leader, `nvim_get_keymap` reports
  -- `<leader>gs` as " gs", and trimming that silently looks up the wrong key.
  local raw_lhs = type(args.lhs) == "string" and args.lhs or ""
  if raw_lhs == "" then
    return { error = 'explain_keymap requires `lhs`, e.g. "<leader>gs"' }
  end

  local lhs = normalize(raw_lhs)
  local modes = args.mode and { args.mode } or MODES

  local mappings = {}
  for _, mode in ipairs(modes) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.lhs == lhs or normalize(m.lhs) == lhs then
        local entry = {
          mode = mode,
          lhs = m.lhs,
          rhs = m.rhs or (m.callback and "<function>" or nil),
          desc = m.desc,
          buffer = false,
          silent = m.silent == 1,
          source = definition_site(mode, m.lhs),
        }
        table.insert(mappings, entry)
      end
    end
  end

  local specs = lazy_key_specs(lhs)

  -- Resolve the owning plugin, then its docs. Live mapping wins; a lazy spec is
  -- the fallback for a plugin that has not loaded.
  local owners = {}
  for _, m in ipairs(mappings) do
    if m.source and m.source.plugin then
      owners[m.source.plugin] = true
    end
  end
  for _, s in ipairs(specs) do
    owners[s.plugin] = true
  end

  -- Built once and reused across every owner below: `docs.run` rebuilds its
  -- corpus per call by design (staleness would be a lie about what is
  -- installed), but nothing here changes what is installed mid-call, so
  -- paying for that N times over buys nothing.
  local doc_corpus = docs.corpus()
  local doc_hits = {}
  for name in pairs(owners) do
    local resolved = docs.run({ query = name, corpus = doc_corpus })
    doc_hits[name] = {
      plugins = resolved.plugins,
      exact = resolved.exact,
    }
  end

  local result = {
    lhs = raw_lhs,
    normalized = lhs,
    mappings = mappings,
    lazy_specs = specs,
    docs = doc_hits,
  }

  if #mappings == 0 and #specs == 0 then
    result.note = ("no mapping for %q in %s. It is not bound here — check for a typo in the lhs, "):format(
      raw_lhs,
      table.concat(modes, "/")
    ) .. "or a plugin that failed to load."
  elseif #mappings == 0 and #specs > 0 then
    result.note = "no live mapping yet: lazy.nvim owns this lhs as a load trigger. "
      .. "Pressing it loads the plugin, which then creates the real mapping."
  end

  return result
end

return M
