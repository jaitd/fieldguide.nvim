-- How a completed tool call reads in the transcript.
--
-- Tool output is most of a transcript's bulk and almost none of its signal, so
-- the default is a capped, collapsible block. The fieldguide verbs get better
-- than that: they return structured JSON we defined ourselves, so there is no
-- excuse for showing the JSON.
--
-- A renderer returns { summary, body, status }. `summary` is the one line always
-- shown; `body` is the detail, hidden until asked for; `status` picks the glyph
-- the line opens with. Renderers name a state, not a character — what that state
-- looks like is this module's business, not theirs.

local M = {}

---@class fieldguide.ToolRender
---@field summary string one line, always visible
---@field body string[]? detail lines, collapsed by default
---@field status "ok"|"fail"|nil default: a plain call that neither passed nor failed
---@field target fieldguide.ToolTarget? the file this call was about, for jumping to

---@class fieldguide.ToolTarget
---@field path string absolute
---@field line integer?

-- Deliberately not nerd-font glyphs. A transcript is the last place to make
-- someone's terminal render a tofu box, and these three carry the whole signal:
-- something ran, something passed, something broke.
M.icons = {
  default = "▪",
  ok = "✓",
  fail = "✗",
}

M.icon_hl = {
  default = "FieldguideToolIcon",
  ok = "FieldguideToolOk",
  fail = "FieldguideToolError",
}

---@param status string?
---@return string glyph, string highlight group
function M.icon(status)
  local key = M.icons[status] and status or "default"
  return M.icons[key], M.icon_hl[key]
end

---@param s string?
---@param n integer
---@return string
local function truncate(s, n)
  s = tostring(s or ""):gsub("%s+", " ")
  if #s <= n then
    return s
  end
  return s:sub(1, n - 1) .. "…"
end

---Our verbs answer through the RPC tool result as a JSON string. Decode it, or
---give up gracefully — a renderer must never be the reason a turn fails.
---@param text string?
---@return table?
local function decode(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(value) == "table" and value or nil
end

---Back to an absolute path, so a transcript line can be opened.
---
---Relative paths are the agent's, and the agent's working directory is the
---config dir — never Neovim's, which is wherever the user happened to start it.
---@param path string?
---@return string?
local function abs_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  if vim.startswith(path, "/") then
    return path
  end
  local ok, cfg = pcall(require, "fieldguide.config")
  return ok and (cfg.paths().config_dir .. "/" .. path) or nil
end

---@param path string?
---@param line integer?
---@return fieldguide.ToolTarget?
local function target_of(path, line)
  local abs = abs_path(path)
  return abs and { path = abs, line = line } or nil
end

---Paths relative to the config dir, because that is the language the rest of
---the output already speaks.
---@param path string?
---@return string
local function short_path(path)
  if type(path) ~= "string" then
    return "?"
  end
  local ok, cfg = pcall(require, "fieldguide.config")
  if ok then
    local util = require("fieldguide.util")
    local p = cfg.paths()

    -- The agent hands back whatever it was given, and it is usually given a
    -- path relative to its own working directory — the config dir. Neovim's
    -- working directory is wherever the user happened to start it, so anything
    -- that resolves a relative path against *that* names a file the agent never
    -- touched. This is the difference between "lua/plugins/formatting.lua" and
    -- a confident, wrong "~/some/project/lua/plugins/formatting.lua".
    path = vim.fs.normalize(path)
    if not vim.startswith(path, "/") then
      path = p.config_dir .. "/" .. path
    end

    -- `is_under` is lexical by contract, and the config dir is routinely a
    -- symlink into a dotfile tree: the same file arrives spelled either way
    -- depending on which tool reported it. Try both spellings before giving up
    -- and printing an absolute path into an 80-column panel.
    local resolved = vim.uv.fs_realpath(path) or path
    for _, root in ipairs({ p.config_dir, p.config_dir_declared }) do
      if util.is_under(path, root) then
        return util.relative(path, root)
      end
      if util.is_under(resolved, root) then
        return util.relative(resolved, root)
      end
    end
    -- Doc-zone paths are long and repetitive; the plugin name is the useful bit.
    local plugin = path:match("/lazy/([^/]+)/(.*)$")
    if plugin then
      return plugin .. "/" .. select(2, path:match("/lazy/([^/]+)/(.*)$"))
    end
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- ---------------------------------------------------------------------------
-- Per-verb renderers
-- ---------------------------------------------------------------------------

local renderers = {}

---`verify` is one line. That is the entire point of it firing on every write.
function renderers.nvim_verify(event)
  local r = decode(event.text)
  if not r then
    return { summary = "verify — no result" }
  end
  local result = r.result or r
  local summary, status
  if result.timed_out then
    summary = ("verify — boot TIMED OUT after %.0fms"):format(result.duration_ms or 0)
    status = "fail"
  elseif result.ok then
    summary = ("verify — boot OK, %.0fms"):format(result.duration_ms or 0)
    status = "ok"
  else
    summary = ("verify — boot FAILED: %s"):format(truncate(result.errors and result.errors[1] or "unknown", 80))
    status = "fail"
  end

  local body = {}
  for _, err in ipairs(result.errors or {}) do
    table.insert(body, "  " .. err)
  end
  if result.note then
    table.insert(body, "  " .. result.note)
  end
  for _, alarm in ipairs(result.escape_alarms or {}) do
    table.insert(body, ("  escape alarm (%s): %s"):format(alarm.kind, alarm.line))
  end
  return { summary = summary, body = #body > 0 and body or nil, status = status }
end

---`docs` is a path and an anchor. Never the corpus.
function renderers.nvim_docs(event)
  local r = decode(event.text)
  local result = r and (r.result or r)
  if not result then
    return { summary = "docs — no result" }
  end

  local hits = {}
  for _, hit in ipairs(result.exact or {}) do
    table.insert(hits, ("  %s  %s:%d"):format(hit.tag, short_path(hit.path), hit.line or 1))
  end
  for _, plugin in ipairs(result.plugins or {}) do
    if plugin.doc_dir then
      table.insert(
        hits,
        ("  %s  %d tags in %s"):format(plugin.plugin, plugin.tag_count or 0, short_path(plugin.doc_dir))
      )
    else
      table.insert(hits, ("  %s  %s"):format(plugin.plugin, plugin.note or short_path(plugin.path)))
    end
  end

  local summary
  if #hits == 0 then
    summary = ("docs %q — not installed here"):format(tostring(result.query))
  else
    summary = ("docs %q — %d resolved"):format(tostring(result.query), #hits + #(result.partial or {}))
  end
  if result.partial and #result.partial > 0 then
    table.insert(hits, ("  + %d partial matches"):format(#result.partial))
  end
  local first = (result.exact or {})[1]
  return {
    summary = summary,
    body = #hits > 0 and hits or nil,
    target = first and target_of(first.path, first.line) or nil,
  }
end

---The join, in three lines: the mapping, where it came from, what documents it.
function renderers.nvim_explain_keymap(event)
  local r = decode(event.text)
  local result = r and (r.result or r)
  if not result then
    return { summary = "explain_keymap — no result" }
  end

  local body = {}
  for _, m in ipairs(result.mappings or {}) do
    table.insert(body, ("  %s %s → %s"):format(m.mode, m.lhs, truncate(m.desc or m.rhs, 60)))
    local src = m.source or {}
    if src.file then
      table.insert(body, ("    from %s%s"):format(short_path(src.file), src.line and (":" .. src.line) or ""))
    end
  end
  for _, spec in ipairs(result.lazy_specs or {}) do
    table.insert(body, ("  lazy trigger for %s%s"):format(spec.plugin, spec.loaded and "" or " (not loaded)"))
  end
  for name, hit in pairs(result.docs or {}) do
    local exact = hit.exact and hit.exact[1]
    if exact then
      table.insert(body, ("    docs %s:%d"):format(short_path(exact.path), exact.line or 1))
    else
      table.insert(body, ("    docs %s"):format(name))
    end
  end

  local owners = vim.tbl_keys(result.docs or {})
  local summary = ("%s — %s"):format(
    tostring(result.lhs),
    #owners > 0 and table.concat(owners, ", ") or (result.note and truncate(result.note, 60) or "no owner found")
  )
  -- The definition site, not the documentation: "where did this key come from"
  -- is the question that wants a jump.
  local src = ((result.mappings or {})[1] or {}).source or {}
  return {
    summary = summary,
    body = #body > 0 and body or nil,
    target = target_of(src.file, src.line),
  }
end

---Sections and their sizes, not their contents.
function renderers.nvim_state(event)
  local r = decode(event.text)
  local result = r and (r.result or r)
  if not result then
    return { summary = "state — no result" }
  end
  local parts, body = {}, {}
  for _, name in ipairs({ "nvim", "buffers", "diagnostics", "plugins", "keymaps", "windows", "lsp", "messages" }) do
    local section = result[name]
    if section ~= nil then
      local n = vim.islist(section) and #section or nil
      table.insert(parts, n and ("%s(%d)"):format(name, n) or name)
    end
  end
  for _, line in ipairs(vim.split(vim.inspect(result), "\n", { plain = true })) do
    table.insert(body, "  " .. line)
  end
  return { summary = "state — " .. table.concat(parts, " "), body = body }
end

---Built-in file tools: the path is the story.
local function file_tool(label)
  return function(event)
    local args = event.args or {}
    local path = args.path or args.dir or args.pattern or "?"
    return { summary = ("%s %s"):format(label, short_path(path)), target = target_of(path) }
  end
end

renderers.read = file_tool("read")
renderers.ls = file_tool("ls")

---A write is a file appearing or being replaced wholesale; its size is the
---only thing worth a number.
function renderers.write(event)
  local args = event.args or {}
  local lines = args.content and (select(2, tostring(args.content):gsub("\n", "")) + 1) or nil
  return {
    summary = ("write %s%s"):format(short_path(args.path), lines and (" — %d line(s)"):format(lines) or ""),
    target = target_of(args.path),
  }
end

---pi computes a display diff for every edit and hands it back in the tool
---result. Showing anything else would be re-deriving what we were given.
function renderers.edit(event)
  local args = event.args or {}
  local details = event.details or {}
  local diff = type(details.diff) == "string" and details.diff or nil

  local body, added, removed = nil, 0, 0
  if diff then
    body = {}
    for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
      if line ~= "" then
        table.insert(body, "  " .. line)
        local sign = line:match("^([+-])%d")
        if sign == "+" then
          added = added + 1
        elseif sign == "-" then
          removed = removed + 1
        end
      end
    end
  end

  local counts = ""
  if added > 0 or removed > 0 then
    counts = (" — +%d −%d"):format(added, removed)
  elseif args.edits then
    counts = (" — %d edit(s)"):format(#args.edits)
  end

  return {
    summary = ("edit %s%s"):format(short_path(args.path), counts),
    body = body and #body > 0 and body or nil,
    target = target_of(args.path, details.firstChangedLine),
  }
end

function renderers.grep(event)
  local args = event.args or {}
  local text = tostring(event.text or "")
  -- Line count is newline count plus one, except for empty output, which is
  -- zero lines rather than one.
  local matches = text == "" and 0 or select(2, text:gsub("\n", "")) + 1
  return {
    summary = ("grep %q%s — %d line(s)"):format(
      tostring(args.pattern),
      args.path and (" in " .. short_path(args.path)) or "",
      matches
    ),
    body = nil,
    target = target_of(args.path),
  }
end
renderers.find = renderers.grep

-- ---------------------------------------------------------------------------

---@param event fieldguide.Event
---@param max_body_lines integer
---@return fieldguide.ToolRender
function M.render(event, max_body_lines)
  local fn = renderers[event.tool or ""]
  local rendered
  if fn then
    local ok, res = pcall(fn, event)
    rendered = ok and res or nil
    if not ok then
      rendered = { summary = ("%s — renderer failed: %s"):format(event.tool, truncate(res, 60)) }
    end
  end

  if not rendered then
    -- Default: name, first line of output, rest collapsed.
    local text = event.text or ""
    local lines = vim.split(text, "\n", { plain = true })
    rendered = {
      summary = ("%s%s"):format(
        event.tool or "tool",
        lines[1] and lines[1] ~= "" and ("  " .. truncate(lines[1], 70)) or ""
      ),
      body = #lines > 1 and vim.tbl_map(function(l)
        return "  " .. l
      end, lines) or nil,
    }
  end

  if event.is_error then
    rendered.summary = rendered.summary .. "  [failed]"
    -- Kept alongside the glyph rather than replaced by it: the colour is gone
    -- the moment a line is yanked out of the transcript, and this is exactly
    -- the line someone pastes somewhere.
    rendered.status = "fail"
  end

  -- The cap is on what is *stored* for display, not on what is kept: a body
  -- longer than this is truncated with a count so the omission is visible.
  if rendered.body and #rendered.body > max_body_lines then
    local kept = vim.list_slice(rendered.body, 1, max_body_lines)
    table.insert(kept, ("  … %d more lines"):format(#rendered.body - max_body_lines))
    rendered.body = kept
  end

  return rendered
end

---Exposed so a test can assert on one renderer without a session.
M._renderers = renderers

return M
