-- setup.lua: what nb_fluid installs outside its own folder, and how it is
-- removed again. Used by the mod and by lib/uninstall.lua.
--
-- fluidsynth runs as a system service, nb-fluid.service, started on demand
-- by the mod (sudo systemctl). It reads shell commands from a FIFO and takes
-- its settings from service.env, which the mod writes before each start.

local LIB_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
local deps = dofile(LIB_DIR .. "/deps.lua")
local platform = deps.platform
local q = platform.shell_quote

local M = {}
M.deps = deps

M.CODE_DIR = LIB_DIR:match("^(.*)/lib$")
M.DATA_DIR = _path.data .. "nb_fluid/"
M.DEPS_DIR = M.DATA_DIR .. "deps"
M.SOUNDFONT_DIR = M.DATA_DIR .. "soundfonts/"
M.ENV_FILE = M.DATA_DIR .. "service.env"
M.UNIT = "nb-fluid.service"
M.UNIT_PATH = "/etc/systemd/system/" .. M.UNIT
M.FIFO = "/tmp/nb_fluid.fifo"
M.PIDFILE = "/tmp/nb_fluid.pid"
M.LOG_FILE = "/tmp/nb_fluid.log"

-- the system GM soundfont linked into SOUNDFONT_DIR; the first found wins
local SYSTEM_SOUNDFONTS = {
  "/usr/share/sounds/sf2/default-GM.sf2",
  "/usr/share/sounds/sf3/default-GM.sf3",
  "/usr/share/soundfonts/default.sf2",
  "/usr/share/soundfonts/FluidR3_GM.sf2",
}
local DEFAULT_LINKS = {
  M.SOUNDFONT_DIR .. "default-GM.sf2",
  M.SOUNDFONT_DIR .. "default-GM.sf3",
}

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function user()
  local name = os.getenv("USER")
  if name == nil or name == "" then name = platform.capture("id -un") end
  return name
end

-- Started only by the mod: no [Install] section, so it never runs at boot.
-- It wants JACK but doesn't require it, so it also starts on desktop norns
-- (no norns-jack.service). If the mod is deleted without uninstalling,
-- ConditionPathExists keeps the leftover unit from starting.
function M.render_unit()
  return table.concat({
    "[Unit]",
    "Description=FluidSynth for the nb_fluid norns mod",
    "Wants=norns-jack.service",
    "After=norns-jack.service",
    "ConditionPathExists=" .. M.CODE_DIR .. "/lib/service.sh",
    "",
    "[Service]",
    "Type=simple",
    "User=" .. user(),
    "LimitRTPRIO=95",
    "LimitMEMLOCK=infinity",
    "EnvironmentFile=" .. M.ENV_FILE,
    "ExecStart=/bin/sh " .. M.CODE_DIR .. "/lib/service.sh",
    "",
  }, "\n")
end

-- a value for systemd's EnvironmentFile
local function env_quote(v)
  return '"' .. tostring(v):gsub('[\\"]', "\\%0") .. '"'
end

-- settings: soundfont, gain, sample_rate, polyphony, jack_id
function M.write_env(settings)
  os.execute("mkdir -p " .. q(M.DATA_DIR))
  local f = assert(io.open(M.ENV_FILE, "w"))
  for _, kv in ipairs {
    { "SOUNDFONT", settings.soundfont },
    { "GAIN", string.format("%.3f", settings.gain) },
    { "SAMPLE_RATE", settings.sample_rate },
    { "POLYPHONY", settings.polyphony },
    { "JACK_ID", settings.jack_id },
    { "FIFO", M.FIFO },
    { "PIDFILE", M.PIDFILE },
    { "LOG", M.LOG_FILE },
  } do
    f:write(kv[1], "=", env_quote(kv[2]), "\n")
  end
  f:close()
end

-- the soundfont link in SOUNDFONT_DIR, if there is one
function M.default_link()
  for _, path in ipairs(DEFAULT_LINKS) do
    local f = io.open(path, "r")
    if f then
      f:close()
      return path
    end
  end
end

-- run systemctl (or anything) as root; false when that isn't possible
function M.priv(cmd)
  local run = platform.wrap_priv(platform.detect(), cmd)
  if not run then return false end
  return os.execute(run .. " >/dev/null 2>&1") == true
end

function M.new_deps()
  local d = deps.new { name = "nb_fluid", dir = M.DEPS_DIR }

  d:add { id = "fluidsynth", label = "FluidSynth", check = "fluidsynth",
          pkg = "fluidsynth", recommends = false,
          why = "the synth, with a small GM soundfont" }

  -- Debian's package enables a fluidsynth user service for everyone; it
  -- must never run a second fluidsynth next to ours. Uninstalling turns it
  -- back on (if the package is still there).
  d:add { id = "user-service", label = "fluidsynth user service off",
          needs = { "fluidsynth" },
          why = "keeps a second fluidsynth from running",
          check_fn = function()
            return not platform.run(
              "systemctl --global is-enabled fluidsynth.service")
          end,
          cmd = "systemctl --global disable fluidsynth.service", priv = true,
          step_label = "disable fluidsynth.service",
          uninstall = { {
            cmd = "[ ! -e /usr/lib/systemd/user/fluidsynth.service ]"
              .. " || systemctl --global enable fluidsynth.service",
            priv = true, step_label = "enable fluidsynth.service",
          } } }

  -- written next to the manifest, then copied into place as root
  local unit = M.render_unit()
  local src = M.DEPS_DIR .. "/" .. M.UNIT
  d:add { id = "service", label = "nb-fluid service", needs = { "fluidsynth" },
          why = "runs fluidsynth for the mod",
          check_fn = function() return read_file(M.UNIT_PATH) == unit end,
          install = { { steps = {
            { cmd = "mkdir -p " .. q(M.DEPS_DIR) .. " && printf '%s' "
                .. q(unit) .. " > " .. q(src),
              step_label = "write " .. M.UNIT },
            { cmd = "install -m 644 " .. q(src) .. " " .. q(M.UNIT_PATH)
                .. " && systemctl daemon-reload",
              priv = true, step_label = "install " .. M.UNIT },
          } } },
          uninstall = { {
            cmd = "systemctl stop " .. M.UNIT .. "; rm -f " .. q(M.UNIT_PATH)
              .. " && systemctl daemon-reload",
            priv = true, step_label = "remove " .. M.UNIT,
          } } }

  local candidates = {}
  for _, path in ipairs(SYSTEM_SOUNDFONTS) do candidates[#candidates + 1] = q(path) end
  local links = {}
  for _, path in ipairs(DEFAULT_LINKS) do links[#links + 1] = q(path) end
  d:add { id = "soundfont", label = "default soundfont", optional = true,
          needs = { "fluidsynth" },
          why = "links the GM soundfont",
          check_fn = function() return M.default_link() ~= nil end,
          cmd = "mkdir -p " .. q(M.SOUNDFONT_DIR)
            .. "; for f in " .. table.concat(candidates, " ") .. "; do"
            .. ' if [ -e "$f" ]; then ln -sfn "$f" '
            .. q(M.SOUNDFONT_DIR .. "default-GM") .. '."${f##*.}"; exit 0; fi;'
            .. ' done; echo "no system soundfont found"; exit 1',
          step_label = "link soundfont",
          uninstall = { {
            cmd = "for f in " .. table.concat(links, " ") .. "; do"
              .. ' if [ -L "$f" ]; then rm -f "$f"; fi; done',
            step_label = "remove soundfont link",
          } } }

  return d
end

-- Undo everything nb_fluid set up, then call on_done(ok). Leaves the mod's
-- folder and system.mods to the caller (the mod menu, or modhousekeeper),
-- and keeps soundfonts the user put in the soundfont folder.
function M.uninstall(on_done)
  local d = deps.new { name = "nb_fluid", dir = M.DEPS_DIR }
  -- a service from before the manifest existed (or put in place by hand)
  -- shouldn't keep running a deleted mod's fluidsynth
  M.priv("systemctl stop " .. M.UNIT)
  d:remove(nil, { on_done = function(ok)
    if ok then
      for _, path in ipairs { M.FIFO, M.PIDFILE, M.ENV_FILE,
                              M.DATA_DIR .. "prefs.data" } do
        os.remove(path)
      end
      os.execute("rm -rf " .. q(M.DEPS_DIR) .. "; rmdir "
        .. q(M.SOUNDFONT_DIR) .. " " .. q(M.DATA_DIR) .. " 2>/dev/null")
    end
    on_done(ok)
  end })
end

return M
