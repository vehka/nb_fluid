-- session.lua: the install state machine behind the UI.
--
-- states: "review"  missing deps listed, waiting for the user
--         "running" a step is executing
--         "failed"  a required step failed (retry or close)
--         "blocked" something cannot be installed from here (shows commands)
--         "done"    everything is in place
--
-- An uninstall session (M.new_uninstall) runs the removal steps stored in
-- the manifest instead, newest install first, and goes through the same
-- states.

local req = ...
local steps_mod = req("steps")
local runner_mod = req("runner")

local Session = {}
Session.__index = Session

local M = {}

-- deps: the Deps instance (for specs and checks); ids: what to ensure
function M.new(deps, ids)
  local self = setmetatable({
    deps = deps,
    items = {},     -- one per missing dep: { spec, steps, blocked, ok }
    queue = {},     -- flat list of { item, step }
    idx = 0,
    state = "done",
    log_lines = {},
    runner = runner_mod.new(deps.dir),
    results = {},
  }, Session)

  local ctx = { dir = deps.dir }
  for _, id in ipairs(ids) do
    local spec = deps:spec(id)
    if deps:check(spec) then
      self.results[id] = true
    else
      local item = { spec = spec }
      local steps, err, hint = steps_mod.plan(spec, deps.platform, ctx)
      if steps then
        item.steps = steps
      else
        item.blocked, item.hint = err, hint
        -- no recipe for this platform: say how to get it by hand
        if spec.manual and not hint then item.blocked = spec.manual end
      end
      self.items[#self.items + 1] = item
    end
  end

  if #self.items == 0 and deps:restart_pending() then
    -- installed earlier, but sclang has not been restarted since
    self.needs_restart = true
  end
  if #self.items > 0 then
    self.state = "review"
    self.sel = 1
    for _, item in ipairs(self.items) do
      if item.blocked and not item.spec.optional then
        self.state = "blocked"
      end
      for _, step in ipairs(item.steps or {}) do
        self.queue[#self.queue + 1] = { item = item, step = step }
      end
    end
  end
  return self
end

-- ids: what to remove (default: everything in the manifest), newest first
function M.new_uninstall(deps, ids)
  local manifest = deps:manifest()
  local self = setmetatable({
    deps = deps,
    mode = "uninstall",
    items = {},
    queue = {},
    idx = 0,
    state = "done",
    log_lines = {},
    runner = runner_mod.new(deps.dir),
    results = {},
  }, Session)

  local wanted
  if ids then
    wanted = {}
    for _, id in ipairs(ids) do wanted[id] = true end
  end
  local ctx = { dir = deps.dir }
  local installed = manifest:ids()
  for i = #installed, 1, -1 do
    local id = installed[i]
    local entry = manifest:get(id)
    if not wanted or wanted[id] then
      local item = { spec = { id = id, label = entry.label,
                              restart = entry.restart }, steps = {} }
      for _, s in ipairs(entry.steps or {}) do
        local step, err, hint = steps_mod.build(s, deps.platform, ctx)
        if not step then
          item.blocked, item.hint = err, hint
          break
        end
        item.steps[#item.steps + 1] = step
      end
      if #item.steps == 0 and not item.blocked then
        -- nothing to undo: just forget it
        manifest:forget(id)
        self.results[id] = true
      else
        self.items[#self.items + 1] = item
      end
    end
  end

  if #self.items > 0 then
    self.state = "review"
    self.sel = 1
    for _, item in ipairs(self.items) do
      if item.blocked then self.state = "blocked" end
      for _, step in ipairs(item.steps) do
        self.queue[#self.queue + 1] = { item = item, step = step }
      end
    end
  end
  return self
end

function Session:has_blocked()
  for _, item in ipairs(self.items) do
    if item.blocked then return true end
  end
  return false
end

function Session:confirm()
  if self.state ~= "review" then return end
  -- skip optional deps we cannot install
  local q = {}
  for _, e in ipairs(self.queue) do
    if not e.item.blocked then q[#q + 1] = e end
  end
  self.queue = q
  if #q == 0 then self.state = "done" return end
  self.idx = 0
  self:next_step()
end

function Session:next_step()
  self.idx = self.idx + 1
  local entry = self.queue[self.idx]
  if not entry then
    self.state = self:ok() and "done" or "failed"
    return
  end
  self.state = "running"
  self.current = entry
  self.progress, self.message, self.tail = nil, nil, ""
  entry.job = self.runner:start(entry.step.run,
    { progress = entry.step.progress })
  self.spin = 0
end

function Session:ok()
  for _, item in ipairs(self.items) do
    if not item.ok and not item.spec.optional then return false end
  end
  return true
end

local function is_last_step(self, entry)
  for i = self.idx + 1, #self.queue do
    if self.queue[i].item == entry.item then return false end
  end
  return true
end

function Session:tick()
  if self.state ~= "running" then return end
  local entry = self.current
  local r = entry.job:poll()
  self.progress, self.message, self.tail = r.progress, r.message, r.tail
  self.spin = (self.spin or 0) + 1
  if not r.done then return end

  if r.code == 0 and self.mode == "uninstall" then
    if is_last_step(self, entry) then
      local spec = entry.item.spec
      entry.item.ok = true
      self.did_remove = true
      self.deps:manifest():forget(spec.id)
      if spec.restart then
        self.needs_restart = true
        self.deps:mark_restart()
      end
      self.results[spec.id] = true
    end
  elseif r.code == 0 then
    if is_last_step(self, entry) then
      if self.deps:check(entry.item.spec) then
        self.deps:record(entry.item.spec)
        entry.item.ok = true
        self.did_install = true
        if entry.item.spec.restart then
          self.needs_restart = true
          self.deps:mark_restart()
        end
        self.results[entry.item.spec.id] = true
      else
        r.code = 1
        self.error = "installed, but the check still fails "
          .. "(is it on matron's PATH?)"
      end
    end
  end
  if r.code ~= 0 then
    self.error = self.error or ("exit code " .. tostring(r.code))
    self.failed = entry
    self.fail_log = entry.job.log
    if entry.item.spec.optional then
      -- give up on this dep, carry on with the rest
      self.results[entry.item.spec.id] = false
      for i = self.idx + 1, #self.queue do
        if self.queue[i].item == entry.item then self.queue[i].skip = true end
      end
      self.error = nil
      return self:advance_past_skipped()
    end
    self.state = "failed"
    self.scroll = 0
    return
  end
  self:advance_past_skipped()
end

function Session:advance_past_skipped()
  self:next_step()
  while self.state == "running" and self.current.skip do
    self:next_step()
  end
end

function Session:retry()
  if self.state ~= "failed" then return end
  self.error = nil
  self.idx = self.idx - 1
  self:next_step()
end

function Session:cancel()
  if self.state == "running" then self.current.job:cancel() end
  self.state = "cancelled"
end

-- last n lines of the current/failed log, apt status noise removed
function Session:log_tail(n, offset)
  local text = self.tail or ""
  if self.state == "failed" and self.failed then
    local f = io.open(self.failed.job.log, "rb")
    if f then text = f:read("a") or ""; f:close() end
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    if not line:match("^%a%astatus:") then lines[#lines + 1] = line end
  end
  local last = #lines - (offset or 0)
  local out = {}
  for i = math.max(1, last - n + 1), last do out[#out + 1] = lines[i] end
  return out, #lines
end

return M
