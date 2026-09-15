-- Tool renderers. The verbs return JSON we defined ourselves, so there is no
-- excuse for showing the JSON.
--
--   nvim -l tests/tools.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

require("fieldguide.config").setup({})
local tools = require("fieldguide.chat.tools")

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

---@param tool string
---@param result table
---@param extra table?
local function event(tool, result, extra)
  return vim.tbl_extend("force", {
    kind = "tool_end",
    tool = tool,
    text = vim.json.encode(result),
    is_error = false,
  }, extra or {})
end

local CAP = 40

io.write("verify\n")
do
  local r = tools.render(event("nvim_verify", { ok = true, result = { ok = true, duration_ms = 61.4 } }), CAP)
  check("a clean boot is one line", r.summary == "verify — boot OK, 61ms", r.summary)
  check("...with nothing collapsed behind it", r.body == nil, vim.inspect(r.body))

  local bad = tools.render(
    event("nvim_verify", { result = { ok = false, duration_ms = 70, errors = { "E5113: attempt to index nil" } } }),
    CAP
  )
  check("a failure names the first error", bad.summary:find("attempt to index nil", 1, true) ~= nil, bad.summary)
  check("...and keeps the rest for expansion", bad.body ~= nil and #bad.body >= 1, vim.inspect(bad.body))

  check("a clean boot reads as passing", r.status == "ok", tostring(r.status))
  check("a failed boot reads as failing", bad.status == "fail", tostring(bad.status))

  local timeout = tools.render(event("nvim_verify", { result = { timed_out = true, duration_ms = 15000 } }), CAP)
  check("a timeout says so", timeout.summary:find("TIMED OUT", 1, true) ~= nil, timeout.summary)
  check("...and counts as a failure", timeout.status == "fail", tostring(timeout.status))

  local alarmed = tools.render(
    event("nvim_verify", {
      result = {
        ok = true,
        duration_ms = 60,
        escape_alarms = { { kind = "network", line = "Network is unreachable" } },
      },
    }),
    CAP
  )
  check(
    "an escape alarm is carried, not dropped",
    table.concat(alarmed.body or {}, " "):find("escape alarm", 1, true) ~= nil,
    vim.inspect(alarmed.body)
  )
end

io.write("docs\n")
do
  local r = tools.render(
    event("nvim_docs", {
      result = {
        query = "fugitive",
        exact = {
          {
            tag = "fugitive-maps",
            path = "/home/x/.local/share/nvim/lazy/vim-fugitive/doc/fugitive.txt",
            line = 312,
          },
        },
        plugins = {},
        partial = {},
      },
    }),
    CAP
  )
  check("a resolved tag summarises as a count", r.summary:find("1 resolved", 1, true) ~= nil, r.summary)
  local body = table.concat(r.body or {}, "\n")
  check("...and the body is a path and an anchor", body:find(":312", 1, true) ~= nil, body)
  check("...with the doc path shortened to the plugin", body:find("vim%-fugitive/doc") ~= nil, body)
  check("the raw JSON never appears", body:find("{", 1, true) == nil, body)

  local absent = tools.render(
    event("nvim_docs", { result = { query = "nope", exact = {}, plugins = {}, partial = {}, note = "not installed" } }),
    CAP
  )
  check(
    "an uninstalled plugin says so in the summary",
    absent.summary:find("not installed", 1, true) ~= nil,
    absent.summary
  )
end

io.write("explain_keymap\n")
do
  local r = tools.render(
    event("nvim_explain_keymap", {
      result = {
        lhs = "<leader>gs",
        mappings = {
          {
            mode = "n",
            lhs = " gs",
            desc = "Git status",
            source = { file = "/home/x/dotfiles/nvim/.config/nvim/init.lua", line = 4 },
          },
        },
        lazy_specs = { { plugin = "telescope.nvim", loaded = false } },
        docs = {
          ["telescope.nvim"] = {
            exact = {
              { path = "/home/x/.local/share/nvim/lazy/telescope.nvim/doc/telescope.txt", line = 4 },
            },
          },
        },
      },
    }),
    CAP
  )
  check("the summary is the mapping and its owner", r.summary:find("telescope.nvim", 1, true) ~= nil, r.summary)
  local body = table.concat(r.body or {}, "\n")
  check("the body carries the definition site", body:find("init.lua:4", 1, true) ~= nil, body)
  check("...the lazy trigger", body:find("lazy trigger", 1, true) ~= nil, body)
  check("...and the doc anchor", body:find("telescope.txt:4", 1, true) ~= nil, body)
end

io.write("keymap definition_site\n")
do
  -- `:verbose nmap gc` lists every mapping whose lhs *starts with* "gc" —
  -- `gcc` included — so naively taking the first "Last set from" in that
  -- output attributes `gc` to wherever `gcc` was defined. Source two files
  -- that each set one of the two, then confirm `gc` resolves to its own file.
  local keymap = require("fieldguide.keymap")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local gcc_file = dir .. "/gcc.lua"
  local gc_file = dir .. "/gc.lua"
  vim.fn.writefile({ 'vim.keymap.set("n", "gcc", function() end, { desc = "toggle line" })' }, gcc_file)
  vim.fn.writefile({ 'vim.keymap.set("n", "gc", function() end, { desc = "comment operator" })' }, gc_file)
  vim.cmd.source(gcc_file)
  vim.cmd.source(gc_file)

  local r = keymap.run({ lhs = "gc", mode = "n" })
  local m = r.mappings[1]
  check("gc has exactly one live mapping", #r.mappings == 1, vim.inspect(r.mappings))
  check(
    "gc is attributed to its own file, not gcc's",
    m and m.source and m.source.file == vim.uv.fs_realpath(gc_file),
    vim.inspect(m and m.source)
  )

  vim.keymap.del("n", "gcc")
  vim.keymap.del("n", "gc")
  vim.fn.delete(dir, "rf")
end

io.write("built-in tools\n")
do
  local r = tools.render({
    kind = "tool_end",
    tool = "read",
    args = { path = "/home/x/dotfiles/nvim/.config/nvim/lua/config/options.lua" },
    text = "…",
  }, CAP)
  check("read is one line naming the file", r.summary:find("options.lua", 1, true) ~= nil, r.summary)
  check("...and collapses nothing", r.body == nil)

  local g = tools.render({ kind = "tool_end", tool = "grep", args = { pattern = "vim.keymap" }, text = "a\nb\nc" }, CAP)
  check("grep reports a match count", g.summary:find("3 line", 1, true) ~= nil, g.summary)

  -- The agent's working directory is the config dir; Neovim's is wherever the
  -- user started it. Resolving a relative path against the wrong one names a
  -- file nothing ever touched, and does it confidently.
  local rel = tools.render({ kind = "tool_end", tool = "read", args = { path = "lua/plugins/formatting.lua" } }, CAP)
  check("a relative path is read against the config dir", rel.summary == "read lua/plugins/formatting.lua", rel.summary)
  check("...not against Neovim's own cwd", rel.summary:find(vim.uv.cwd(), 1, true) == nil, rel.summary)
end

io.write("edits show their diff\n")
do
  -- pi computes a display diff for every edit and hands it back in the tool
  -- result: `+NN text` / `-NN text`, with unprefixed context.
  local e = tools.render({
    kind = "tool_end",
    tool = "edit",
    args = { path = "lua/plugins/formatting.lua", edits = { { oldText = "a", newText = "b" } } },
    details = {
      diff = ' 10 local opts = {\n-11   lua = { "stylua" },\n+11   lua = { "stylua", "styluafmt" },\n+12   toml = { "taplo" },\n 13 }',
      firstChangedLine = 11,
    },
  }, CAP)
  check("the summary counts the change", e.summary == "edit lua/plugins/formatting.lua — +2 −1", e.summary)
  check("the diff is what is collapsed behind it", e.body ~= nil and #e.body == 5, vim.inspect(e.body))
  check("...including its context lines", table.concat(e.body or {}, "\n"):find("local opts", 1, true) ~= nil)
  check("the jump lands on the first change", e.target and e.target.line == 11, vim.inspect(e.target))
  check(
    "...at an absolute path",
    e.target and e.target.path:sub(1, 1) == "/" and e.target.path:find("formatting.lua", 1, true) ~= nil,
    vim.inspect(e.target)
  )

  -- An edit whose result carried no diff still renders.
  local bare = tools.render({ kind = "tool_end", tool = "edit", args = { path = "init.lua", edits = { {}, {} } } }, CAP)
  check("an edit with no diff falls back to a count", bare.summary == "edit init.lua — 2 edit(s)", bare.summary)
  check("...and collapses nothing", bare.body == nil, vim.inspect(bare.body))
end

io.write("targets\n")
do
  local r = tools.render({ kind = "tool_end", tool = "read", args = { path = "lua/config/options.lua" } }, CAP)
  check("a read is jumpable", r.target ~= nil and r.target.path:sub(1, 1) == "/", vim.inspect(r.target))
  check(
    "...to the file it named",
    (r.target or {}).path:find("lua/config/options.lua", 1, true) ~= nil,
    vim.inspect(r.target)
  )

  local k = tools.render(
    event("nvim_explain_keymap", {
      result = {
        lhs = "<leader>gs",
        mappings = { { mode = "n", lhs = " gs", source = { file = "/tmp/x/init.lua", line = 12 } } },
        docs = {},
      },
    }),
    CAP
  )
  -- The definition site, not the documentation: "where did this key come from"
  -- is the question that wants a jump.
  check(
    "explain_keymap jumps to the definition site",
    vim.deep_equal(k.target, { path = "/tmp/x/init.lua", line = 12 }),
    vim.inspect(k.target)
  )

  local v = tools.render(event("nvim_verify", { result = { ok = true, duration_ms = 60 } }), CAP)
  check("a call about no file has nothing to jump to", v.target == nil, vim.inspect(v.target))
end

io.write("the default renderer\n")
do
  local lines = {}
  for i = 1, 200 do
    table.insert(lines, "line " .. i)
  end
  local r = tools.render({ kind = "tool_end", tool = "some_unknown_tool", text = table.concat(lines, "\n") }, CAP)
  check("an unknown tool still renders", r.summary:find("some_unknown_tool", 1, true) ~= nil, r.summary)
  check("...capped at the configured limit", #r.body == CAP + 1, tostring(#r.body))
  check("...and says how much it dropped", r.body[#r.body]:find("160 more lines", 1, true) ~= nil, r.body[#r.body])
end

io.write("robustness\n")
do
  local r = tools.render({ kind = "tool_end", tool = "nvim_verify", text = "not json at all" }, CAP)
  check("undecodable output does not throw", type(r.summary) == "string", vim.inspect(r))

  local e = tools.render(event("nvim_verify", { result = { ok = true, duration_ms = 60 } }, { is_error = true }), CAP)
  check("a failed call is marked", e.summary:find("[failed]", 1, true) ~= nil, e.summary)
  check("...in the glyph as well as the text", e.status == "fail", tostring(e.status))

  local empty = tools.render({ kind = "tool_end", tool = "read", args = {} }, CAP)
  check("a tool with no args renders something", type(empty.summary) == "string" and empty.summary ~= "", empty.summary)
end

io.write("glyphs\n")
do
  local plain, plain_hl = tools.icon(nil)
  local ok, ok_hl = tools.icon("ok")
  local fail, fail_hl = tools.icon("fail")
  check(
    "every state gets its own glyph",
    plain ~= ok and ok ~= fail and plain ~= fail,
    table.concat({ plain, ok, fail }, " ")
  )
  check(
    "...and its own highlight",
    plain_hl ~= ok_hl and ok_hl ~= fail_hl,
    table.concat({ plain_hl, ok_hl, fail_hl }, " ")
  )
  check("an unknown state falls back rather than vanishing", tools.icon("wat") == plain, tools.icon("wat"))

  local hl = require("fieldguide.chat.highlight")
  for _, name in ipairs({ plain_hl, ok_hl, fail_hl, "FieldguideTool", "FieldguideToolDetail" }) do
    check(("%s is a defined group"):format(name), hl.links[name] ~= nil, name)
  end
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
