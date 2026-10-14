-- deps.lua: declare, check and install a norns script's dependencies.
--
--   local deps = include("lib/deps")
--   local d = deps.new { name = "myscript", dir = _path.data .. "myscript/deps" }
--   d:add { id = "sox", check = "sox", pkg = "sox", size = "1 MB",
--           why = "resamples rendered audio" }
--   if not d:ok("sox") then d:ensure({ "sox" }, { on_done = function(ok) end }) end
--   d:remove(nil, { on_done = function(ok) end })  -- uninstall what it put in
--
-- See README.md for the spec format.

-- Load with require or norns' include(): submodules are found next to this
-- file (lib/deps/), whatever name the script gave its directory.
local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local loaded = {}
local function req(name)
  if not loaded[name] then
    loaded[name] = assert(loadfile(dir .. "/deps/" .. name .. ".lua"))(req)
  end
  return loaded[name]
end
local platform = req("platform")
local steps = req("steps")
local ugens = req("ugens")
local session_mod = req("session")
local manifest_mod = req("manifest")
local ui = req("ui")

local Deps = {}
Deps.__index = Deps

local M = {}
M.platform = platform
M.ugens = ugens
M.steps = steps
M.runner = req("runner")
M.manifest = manifest_mod
-- prefix for shell commands that should see pipx / /usr/local binaries
M.PATH_EXPORT = platform.PATH_EXPORT

function M.new(opts)
  local self = setmetatable({
    name = opts.name or "script",
    dir = opts.dir,
    specs = {},
    order = {},
    platform = opts.platform or platform.detect(),
  }, Deps)
  assert(self.dir, "deps.new: dir is required")
  return self
end

local function normalize(spec)
  assert(spec.id, "dependency needs an id")
  if not spec.install then
    local step = {}
    for _, k in ipairs { "pkg", "recommends", "pipx", "url", "dest", "sha256",
                         "extract", "ugens", "into", "cmd", "priv",
                         "step_label", "progress" } do
      step[k] = spec[k]
    end
    if next(step) then spec.install = { { steps = { step } } } end
  end
  spec.install = spec.install or {}
  -- UGens go in a folder named after the dependency, and sclang has to be
  -- restarted before it sees them
  for _, recipe in ipairs(spec.install) do
    for _, step in ipairs(recipe.steps or {}) do
      if step.ugens then
        step.into = step.into or spec.id
        if spec.restart == nil then spec.restart = true end
      end
    end
  end
  return spec
end

function Deps:add(spec)
  spec = normalize(spec)
  self.specs[spec.id] = spec
  self.order[#self.order + 1] = spec.id
  return spec
end

function Deps:spec(id)
  return assert(self.specs[id], "unknown dependency: " .. tostring(id))
end

local function as_list(v)
  if v == nil then return {} end
  if type(v) == "table" then return v end
  return { v }
end

-- is this dependency in place right now? cheap, synchronous
function Deps:check(spec)
  if type(spec) == "string" then spec = self:spec(spec) end
  if spec.check_fn then return spec.check_fn() and true or false end
  local checked = false
  for _, name in ipairs(as_list(spec.check)) do
    checked = true
    if not platform.have(name) then return false end
  end
  for _, path in ipairs(as_list(spec.check_file)) do
    checked = true
    local f = io.open(steps.expand(self.platform, path), "r")
    if not f then return false end
    f:close()
  end
  for _, name in ipairs(as_list(spec.check_ugens)) do
    checked = true
    if not ugens.installed(self.platform, name) then return false end
  end
  return checked
end

Deps.ok = Deps.check

-- { id = bool, ... } for ids (default: everything added)
function Deps:status(ids)
  local out = {}
  for _, id in ipairs(ids or self.order) do out[id] = self:check(id) end
  return out
end

function Deps:missing(ids)
  local out = {}
  for _, id in ipairs(ids or self.order) do
    if not self:check(id) then out[#out + 1] = id end
  end
  return out
end

-- Uninstall bookkeeping. A dependency that a session installs is written to
-- the manifest with the steps that remove it again: its `uninstall` list,
-- or for package, pipx, UGen and plain download steps, their opposites.
function Deps:manifest()
  if not self._manifest then self._manifest = manifest_mod.open(self.dir) end
  return self._manifest
end

function Deps:record(spec)
  if type(spec) == "string" then spec = self:spec(spec) end
  local removal = spec.uninstall
    or steps.derive_removal(steps.recipe(spec, self.platform))
  self:manifest():record(spec.id, {
    label = spec.label,
    at = os.time(),
    restart = spec.restart or nil,
    steps = removal,
  })
end

-- ids this library installed (and can remove), oldest first
function Deps:installed()
  return self:manifest():ids()
end

-- duplicate UGen/class files on the SC class path: { name = { paths } }
function Deps:ugen_conflicts(names)
  return ugens.duplicates(self.platform, names)
end

-- Restart tracking. A dependency with `restart = true` (new UGens, classes)
-- is only usable after sclang has been restarted. The install time goes in a
-- marker file; it is stale when sclang started before it.
function Deps:marker_path()
  return self.dir .. "/restart_needed"
end

function Deps:mark_restart()
  local f = io.open(self:marker_path(), "w")
  if f then f:write(tostring(os.time())) f:close() end
end

-- seconds sclang has been running, nil when it isn't
function Deps.sclang_uptime()
  local pid = platform.capture("pgrep -x sclang | head -n 1")
  if pid == "" then return nil end
  return tonumber(platform.capture("ps -o etimes= -p " .. pid))
end

function Deps:restart_pending()
  local f = io.open(self:marker_path(), "r")
  if not f then return false end
  local installed = tonumber(f:read("a"))
  f:close()
  local uptime = self.sclang_uptime()
  return installed ~= nil and uptime ~= nil and installed > os.time() - uptime
end

function Deps:jack_files_missing()
  return platform.jack_files_missing(self.platform)
end

-- reboot the device (a restart can't recover from missing JACK files)
function Deps.reboot()
  if norns and norns.state then
    norns.state.clean_shutdown = true
    norns.state.save()
  end
  if _norns and _norns.execute then _norns.execute("sudo shutdown -r now") end
end

-- restart sclang and matron (what SYSTEM > RESTART does at its end)
function Deps.restart()
  if _norns and _norns.reset then _norns.reset() end
end

-- ids plus everything they `need`, dependencies first, no repeats
function Deps:expand(ids)
  local out, seen = {}, {}
  local function visit(id)
    if seen[id] then return end
    seen[id] = true
    local spec = self:spec(id)
    for _, need in ipairs(as_list(spec.needs)) do visit(need) end
    for _, recipe in ipairs(spec.install or {}) do
      if steps.matches(recipe.when, self.platform) then
        for _, need in ipairs(as_list(recipe.needs)) do visit(need) end
        break
      end
    end
    out[#out + 1] = id
  end
  for _, id in ipairs(ids or self.order) do visit(id) end
  return out
end

-- headless session, for tests and custom UIs
function Deps:session(ids)
  return session_mod.new(self, self:expand(ids))
end

-- Show a session on the screen. Takes over key/enc/redraw until it closes,
-- then puts the script's (or the menu's) own handlers back and calls finish.
local function open_ui(s, finish)
  local running = true
  local menu_active = norns.menu.status()
  local saved = {
    key = key, enc = enc, redraw = redraw, refresh = refresh,
    script_redraw = norns.script.redraw,
  }
  if menu_active then
    saved.menu = {
      enc = norns.menu.get_enc(), key = norns.menu.get_key(),
      redraw = norns.menu.get_redraw(), refresh = norns.menu.get_refresh(),
    }
  end

  local function installer_redraw() ui.draw(s) end
  local function installer_enc(n, d)
    ui.enc(s, n, d)
    installer_redraw()
  end
  local close
  local function installer_key(n, z)
    if ui.key(s, n, z) then close() else installer_redraw() end
  end

  -- norns restores `redraw` from norns.script.redraw, and `_menu.key` and
  -- the encoder callback from the globals, whenever the menu is left or
  -- norns.menu.init() runs, so all of them have to point at the installer.
  local function take_over()
    key, enc, redraw, refresh = installer_key, installer_enc,
      installer_redraw, installer_redraw
    norns.script.redraw = installer_redraw
    if menu_active then
      norns.menu.set(installer_enc, installer_key, installer_redraw,
        installer_redraw)
    else
      norns.menu.init()
      -- init() leaves the screen to the script; draw ours again
      redraw = installer_redraw
    end
  end

  function close()
    running = false
    key, enc, refresh = saved.key, saved.enc, saved.refresh
    norns.script.redraw = saved.script_redraw
    if menu_active then
      redraw = saved.redraw
      norns.menu.set(saved.menu.enc, saved.menu.key, saved.menu.redraw,
        saved.menu.refresh)
    else
      redraw = saved.script_redraw or saved.redraw
      norns.menu.init()
    end
    finish()
    if menu_active then
      if saved.menu.redraw then saved.menu.redraw() end
    elseif redraw then
      redraw()
    end
  end

  take_over()
  clock.run(function()
    while running do
      clock.sleep(0.25)
      if running then
        s:tick()
        if running then installer_redraw() end
      end
    end
  end)
  installer_redraw()
end

-- Open the install screen, then call
-- opts.on_done(ok, results, did_install, needs_restart).
-- Does nothing (calls on_done at once) when everything is already in place.
function Deps:ensure(ids, opts)
  opts = opts or {}
  local s = self:session(ids)
  local function finish()
    local ok = s:ok()
    if opts.on_done then
      opts.on_done(ok, s.results, s.did_install, s.needs_restart)
    end
  end
  if s.state == "done" and not s.needs_restart then
    finish()
    return s
  end
  open_ui(s, finish)
  return s
end

-- headless uninstall session, for tests and custom UIs
function Deps:uninstall_session(ids)
  return session_mod.new_uninstall(self, ids)
end

-- Open the uninstall screen for ids (default: everything in the manifest),
-- then call opts.on_done(ok, results, did_remove, needs_restart). ok is
-- false when the user cancelled or a step failed. Needs only `name` and
-- `dir`, not the dependency specs.
function Deps:remove(ids, opts)
  opts = opts or {}
  local s = self:uninstall_session(ids)
  local function finish()
    local ok = s.state ~= "cancelled" and s:ok()
    if opts.on_done then
      opts.on_done(ok, s.results, s.did_remove, s.needs_restart)
    end
  end
  if s.state == "done" then
    finish()
    return s
  end
  open_ui(s, finish)
  return s
end

return M
