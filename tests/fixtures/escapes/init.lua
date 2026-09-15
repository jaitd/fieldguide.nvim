-- Fixture: a config that tries to leave the sandbox. Nothing here is supposed
-- to succeed. The test asserts what the *host* looks like afterwards, because
-- that is the only claim the sandbox actually makes — under bwrap the write
-- below lands on a tmpfs and vanishes, under seatbelt it is refused outright,
-- and either way the file must not exist on the real machine.
local marker = vim.fn.expand("~/.fieldguide-escape-test")
local f = io.open(marker, "w")
if f then
  f:write("escaped")
  f:close()
end

-- Print, so it reaches stdout where the escape alarms can see it.
if vim.fn.executable("curl") == 1 then
  print(vim.fn.system({ "curl", "-sS", "--max-time", "3", "https://example.com" }))
end
