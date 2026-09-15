-- Runs *inside* the verify sandbox, after the user's config has booted.
--
-- Bound in read-only and executed with `-c luafile`. It must not require
-- anything from fieldguide: the plugin is not on the sandboxed runtimepath, and
-- the point is to observe the config as it actually is.
--
-- Writes one JSON object to stdout between markers. Everything else on
-- stdout/stderr is the boot's own output and is captured separately.

local ok_all, payload = pcall(function()
  local out = {}

  out.startup_ms = nil
  if type(vim.g.__fieldguide_t0) == "number" then
    out.startup_ms = math.floor((vim.uv.hrtime() - vim.g.__fieldguide_t0) / 1e4) / 100
  end

  out.errmsg = vim.v.errmsg ~= "" and vim.v.errmsg or nil

  local ok_msg, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if ok_msg then
    out.messages = vim.split(res.output or "", "\n", { trimempty = true })
  end

  local ok_lazy, lazy_cfg = pcall(require, "lazy.core.config")
  if ok_lazy then
    local loaded, not_installed, errored = {}, {}, {}
    for name, p in pairs(lazy_cfg.plugins) do
      local meta = p._ or {}
      if meta.loaded then
        table.insert(loaded, name)
      end
      if p.dir and not vim.uv.fs_stat(p.dir) then
        table.insert(not_installed, name)
      end
      if meta.has_errors then
        table.insert(errored, name)
      end
    end
    table.sort(loaded)
    table.sort(not_installed)
    table.sort(errored)
    out.plugins = {
      total = vim.tbl_count(lazy_cfg.plugins),
      loaded = loaded,
      -- Read-only mounts and --unshare-net mean a missing plugin is *reported*,
      -- not installed. That is a true answer to "does what is on disk boot".
      would_install = not_installed,
      errored = errored,
    }
  end

  return out
end)

io.write("\n<<<FIELDGUIDE\n")
if ok_all then
  io.write(vim.json.encode(payload))
else
  io.write(vim.json.encode({ probe_error = tostring(payload) }))
end
io.write("\nFIELDGUIDE>>>\n")
