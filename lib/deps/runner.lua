-- runner.lua: run shell commands as detached background jobs.
--
-- norns.system_cmd only calls back once, when the command is done, and not at
-- all when it fails. A job here is a small sh script that writes its output
-- to a log and its exit code to a status file; the caller polls. The job
-- lives in its own session, so it survives the script and can be cancelled
-- as a group.

local req = ...
local platform = req("platform")

local Job = {}
Job.__index = Job

local M = {}
local counter = 0

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function read_tail(path, bytes)
  local f = io.open(path, "rb")
  if not f then return "" end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - bytes))
  local s = f:read("a") or ""
  f:close()
  return (s:gsub("\r", "\n"))
end

-- progress parsers return 0..1, plus an optional message
local parsers = {}

-- apt-get -o APT::Status-Fd=1 lines: dlstatus:N:PCT:msg / pmstatus:PKG:PCT:msg
function parsers.apt(tail)
  local lines = {}
  for line in tail:gmatch("[^\n]+") do lines[#lines + 1] = line end
  for i = #lines, 1, -1 do
    local kind, _, pct, msg = lines[i]:match("^(%a%a)status:(.-):([%d%.]+):(.*)$")
    if kind then
      pct = (tonumber(pct) or 0) / 100
      if kind == "dl" then return pct * 0.4, msg end
      return 0.4 + pct * 0.6, msg
    end
  end
end

-- wget / curl print "NN%" while downloading
function parsers.percent(tail)
  local last
  for pct in tail:gmatch("(%d+%.?%d*)%%") do last = pct end
  if last then return math.min(tonumber(last) / 100, 1) end
end

function M.new(dir)
  os.execute("mkdir -p " .. platform.shell_quote(dir))
  return setmetatable({ dir = dir }, { __index = M })
end

-- opts.progress: "apt" | "percent" | nil
function M:start(cmd, opts)
  opts = opts or {}
  counter = counter + 1
  local base = string.format("%s/job%d_%d", self.dir, os.time(), counter)
  local job = setmetatable({
    base = base,
    log = base .. ".log",
    status = base .. ".status",
    pidfile = base .. ".pid",
    parser = parsers[opts.progress],
    started = os.time(),
  }, Job)

  local q = platform.shell_quote
  local script = table.concat({
    "echo $$ > " .. q(job.pidfile),
    "export " .. platform.PATH_EXPORT:gsub("; $", ""),
    "(",
    cmd,
    ") > " .. q(job.log) .. " 2>&1",
    "echo $? > " .. q(job.status .. ".tmp"),
    "mv " .. q(job.status .. ".tmp") .. " " .. q(job.status),
    "",
  }, "\n")
  local f = assert(io.open(base .. ".sh", "w"))
  f:write(script)
  f:close()

  local launcher = platform.have("setsid") and "setsid " or ""
  os.execute(string.format("%ssh %s </dev/null >/dev/null 2>&1 &",
    launcher, q(base .. ".sh")))
  return job
end

local function alive(pid)
  return pid and io.open("/proc/" .. pid, "r") ~= nil
end

-- returns { done, code, progress, message, tail }
function Job:poll()
  if self.result then return self.result end
  local tail = read_tail(self.log, 4096)
  local r = { done = false, tail = tail }
  if self.parser then r.progress, r.message = self.parser(tail) end

  local status = read_file(self.status)
  if status then
    r.done, r.code = true, tonumber(status) or 1
  else
    if not self.pid then
      self.pid = (read_file(self.pidfile) or ""):match("%d+")
    end
    -- started more than a few seconds ago, pid known, but gone: killed
    if self.pid and not alive(self.pid) and not read_file(self.status) then
      r.done, r.code = true, 143
    end
  end
  if r.done then
    self:cleanup()
    self.result = r
  end
  return r
end

function Job:cancel()
  if not self.pid then
    self.pid = (read_file(self.pidfile) or ""):match("%d+")
  end
  if self.pid then
    os.execute("kill -TERM -- -" .. self.pid .. " 2>/dev/null; "
      .. "kill -TERM " .. self.pid .. " 2>/dev/null")
  end
end

-- drop the script and bookkeeping files, keep the log for the error screen
function Job:cleanup()
  os.remove(self.base .. ".sh")
  os.remove(self.pidfile)
  os.remove(self.status)
end

return M
