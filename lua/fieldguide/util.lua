-- Path helpers shared by the verbs and (in spirit) by the extension's gate.

local M = {}

---Resolve symlinks where possible; fall back to the absolute path so a
---not-yet-existing file still compares sensibly.
---@param p string
---@return string
function M.resolve(p)
  local abs = vim.fn.fnamemodify(p, ":p")
  -- fnamemodify(":p") appends a trailing slash to directories.
  abs = abs:gsub("/+$", "")
  return vim.uv.fs_realpath(abs) or abs
end

---Prefix test on already-resolved paths. Guards against `/foo/barbaz` matching
---the root `/foo/bar`.
---@param path string
---@param root string?
---@return boolean
function M.is_under(path, root)
  if not root or root == "" then
    return false
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

---@param path string
---@param root string?
---@return string
function M.relative(path, root)
  if root and M.is_under(path, root) then
    if path == root then
      return "."
    end
    return path:sub(#root + 2)
  end
  return path
end

---Read a whole file, or nil.
---@param path string
---@return string?
function M.read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

return M
