-- nb_fluid
-- fluidsynth as nb voices: General MIDI on norns via soundfonts.
--
-- fluidsynth runs as a system service (nb-fluid.service, see lib/setup.lua)
-- that the mod starts on demand and feeds shell commands through a FIFO.
-- its JACK outputs are wired into crone's engine inputs, so it follows
-- the ENGINE level and the norns reverb / tape like any engine would.
-- each nb voice "fluid N" plays MIDI channel N.

local mod = require 'core/mods'

local mod_name = mod.this_name or "nb_fluid"
local gm = require(mod_name .. '/lib/gm')
local setup = require(mod_name .. '/lib/setup')

local DATA_DIR = setup.DATA_DIR
local PREFS_FILE = DATA_DIR .. "prefs.data"
local LOG_FILE = setup.LOG_FILE
local FIFO = setup.FIFO
local JACK_ID = "nb_fluid"
local SOUNDFONT_DIR = setup.SOUNDFONT_DIR
-- the engine inputs; SuperCollider uses the same pair
local ROUTES = {
  { JACK_ID .. ":left", "crone:input_5" },
  { JACK_ID .. ":right", "crone:input_6" },
}
local MAX_VOICES = 16
local POLYPHONY = 64
-- norns runs JACK at 48k; fluidsynth's reverb can't follow a later rate change
local SAMPLE_RATE = 48000
-- what start() can't do without; the rest is offered alongside them
local REQUIRED = { "fluidsynth", "service" }

local prefs = {
  voices = 4,
  soundfont = nil,
  gain = 0.5,
}

local fluid = {
  -- the FIFO's write end, while fluidsynth runs
  out = nil,
  pid = nil,
  started_at = 0,
  checked_at = 0,
  -- fluidsynth numbers soundfonts per process, counting every load
  sfont_id = 1,
  soundfont = nil,
  -- a soundfont being loaded into the running fluidsynth
  loading = nil,
  -- set when starting failed, so note_on doesn't retry on every note
  failed = false,
  -- the install screen was offered this session
  offered = false,
}

local deps_cache
local function get_deps()
  if not deps_cache then deps_cache = setup.new_deps() end
  return deps_cache
end

------------------------------------------------------------------------
-- prefs

local function read_prefs()
  if util.file_exists(PREFS_FILE) then
    local saved = tab.load(PREFS_FILE)
    if saved then
      for k, v in pairs(saved) do
        prefs[k] = v
      end
    end
  end
  prefs.voices = util.clamp(prefs.voices, 1, MAX_VOICES)
end

-- After an uninstall (from the mod menu or modhousekeeper) the mod stays
-- loaded until norns restarts; with its folder gone, it must not write
-- prefs, the env file or start the service again.
local function uninstalled()
  return not util.file_exists(setup.CODE_DIR .. "/lib/mod.lua")
end

local function write_prefs()
  if uninstalled() then return end
  tab.save(prefs, PREFS_FILE)
end

local function find_soundfonts()
  local found = {}
  if util.file_exists(SOUNDFONT_DIR) then
    for _, name in ipairs(util.scandir(SOUNDFONT_DIR)) do
      if name:lower():match("%.sf[23]$") then
        table.insert(found, SOUNDFONT_DIR .. name)
      end
    end
  end
  return found
end

local function basename(path)
  return path and path:match("([^/]+)$") or "none"
end

------------------------------------------------------------------------
-- fluidsynth service

local function close_fifo()
  if fluid.out then
    fluid.out:close()
    fluid.out = nil
  end
  fluid.loading = nil
end

local function read_from(path, offset)
  local f = io.open(path, "r")
  if not f then return "" end
  f:seek("set", offset)
  local s = f:read("a") or ""
  f:close()
  return s
end

local function file_size(path)
  local f = io.open(path, "r")
  if not f then return 0 end
  local size = f:seek("end")
  f:close()
  return size
end

-- the service writes its pid before it execs fluidsynth
local function process_alive()
  if not fluid.pid then
    local f = io.open(setup.PIDFILE, "r")
    if f then
      fluid.pid = f:read("l")
      f:close()
    end
    if not fluid.pid then
      -- still starting up
      return util.time() - fluid.started_at < 15
    end
  end
  local f = io.open("/proc/" .. fluid.pid .. "/stat", "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- A stopped fluidsynth no longer drains the FIFO, and a full FIFO would
-- block matron, so writes stop as soon as the process is gone.
local function send(line)
  if not fluid.out then return end
  local now = util.time()
  if now - fluid.checked_at > 1 then
    fluid.checked_at = now
    if not process_alive() then
      print("nb_fluid: fluidsynth stopped, see " .. LOG_FILE)
      close_fifo()
      fluid.failed = true
      return
    end
  end
  fluid.out:write(line, "\n")
  fluid.out:flush()
end

-- a path for fluidsynth's shell
local function shell_path(path)
  return '"' .. path:gsub('[\\"$`]', "\\%0") .. '"'
end

local function connect_routes()
  for _, r in ipairs(ROUTES) do
    if _norns.audio_connect then
      _norns.audio_connect(r[1], r[2])
    else
      os.execute("jack_connect " .. r[1] .. " " .. r[2] .. " >/dev/null 2>&1")
    end
  end
end

local function jack_port_exists(name)
  if not _norns.audio_get_output_ports then
    return true
  end
  for _, p in ipairs(_norns.audio_get_output_ports()) do
    if p == name then
      return true
    end
  end
  return false
end

-- the JACK client shows up only once fluidsynth has loaded the soundfont
local function connect_when_ready()
  local out = fluid.out
  clock.run(function()
    for _ = 1, 120 do
      if fluid.out ~= out then
        return
      end
      if jack_port_exists(ROUTES[1][1]) then
        connect_routes()
        return
      end
      if not process_alive() then
        break
      end
      clock.sleep(0.25)
    end
    print("nb_fluid: fluidsynth JACK ports never appeared, see " .. LOG_FILE)
  end)
end

local apply_all_voices
local start
local sync_shared_params
-- voices a script is playing (see the voices section)
local in_use = {}

-- after an install: start right away if a script already uses a voice,
-- rather than waiting for its next note
local function start_if_in_use()
  fluid.failed = false
  if next(in_use) then
    start()
  end
end

-- Opens the install screen, once per session. Deferred, so it doesn't open
-- in the middle of a script's init (loading a script resets the handlers).
local function offer_install()
  if fluid.offered then return end
  fluid.offered = true
  print("nb_fluid: fluidsynth or its service is missing; opening the installer")
  clock.run(function()
    clock.sleep(0.5)
    get_deps():ensure(nil, { on_done = function(ok)
      if ok then
        print("nb_fluid: dependencies installed")
      end
      start_if_in_use()
    end })
  end)
end

start = function()
  if fluid.out then
    return true
  end
  if fluid.failed or uninstalled() then
    return false
  end
  fluid.failed = true
  local d = get_deps()
  for _, id in ipairs(REQUIRED) do
    if not d:check(id) then
      offer_install()
      return false
    end
  end
  if prefs.soundfont == nil or not util.file_exists(prefs.soundfont) then
    prefs.soundfont = find_soundfonts()[1]
  end
  if prefs.soundfont == nil then
    print("nb_fluid: no soundfont found; put a .sf2 in " .. SOUNDFONT_DIR)
    return false
  end

  setup.write_env {
    soundfont = prefs.soundfont, gain = prefs.gain,
    sample_rate = SAMPLE_RATE, polyphony = POLYPHONY, jack_id = JACK_ID,
  }
  os.remove(setup.PIDFILE)
  local q = setup.deps.platform.shell_quote
  if not os.execute("[ -p " .. q(FIFO) .. " ] || { rm -f " .. q(FIFO)
      .. " && mkfifo -m 600 " .. q(FIFO) .. "; }") then
    print("nb_fluid: couldn't make " .. FIFO)
    return false
  end
  -- read-write: never blocks, and writes can't SIGPIPE matron
  fluid.out = io.open(FIFO, "r+")
  if fluid.out == nil then
    print("nb_fluid: couldn't open " .. FIFO)
    return false
  end
  -- restart, not start: one left over from before a matron restart has
  -- an unknown soundfont loaded
  if not setup.priv("systemctl restart " .. setup.UNIT) then
    print("nb_fluid: couldn't start " .. setup.UNIT)
    close_fifo()
    return false
  end
  fluid.pid = nil
  fluid.started_at = util.time()
  fluid.checked_at = fluid.started_at
  fluid.sfont_id = 1
  fluid.soundfont = prefs.soundfont
  fluid.failed = false
  print("nb_fluid: started fluidsynth with " .. basename(prefs.soundfont))
  sync_shared_params()
  connect_when_ready()
  -- commands queue in the FIFO until the soundfont has loaded
  apply_all_voices()
  return true
end

local function stop()
  close_fifo()
  setup.priv("systemctl stop " .. setup.UNIT)
end

-- Swap the soundfont in the running fluidsynth: load the new one, point
-- the voices at it, unload the old one. fluidsynth reports the new id in
-- its output (the log), so a failed load can't throw the ids off.
-- Notes keep playing on the old soundfont until the new one has loaded.
local function load_soundfont(path)
  if not fluid.out or fluid.loading or path == fluid.soundfont then return end
  if not util.file_exists(path) then return end
  local offset = file_size(LOG_FILE)
  fluid.loading = path
  send("load " .. shell_path(path))
  clock.run(function()
    -- big soundfonts take a while on a pi
    for _ = 1, 240 do
      clock.sleep(0.25)
      if fluid.loading ~= path then return end
      local out = read_from(LOG_FILE, offset)
      local id = out:match("loaded SoundFont has ID (%d+)")
      if id then
        local old = fluid.sfont_id
        fluid.sfont_id = tonumber(id)
        fluid.soundfont = path
        fluid.loading = nil
        apply_all_voices()
        send("unload " .. old)
        print("nb_fluid: switched to " .. basename(path))
        -- changed again while this one was loading
        if prefs.soundfont ~= path then load_soundfont(prefs.soundfont) end
        return
      elseif out:match("failed to load the SoundFont") then
        fluid.loading = nil
        print("nb_fluid: couldn't load " .. basename(path) .. ", see " .. LOG_FILE)
        return
      end
    end
    fluid.loading = nil
    print("nb_fluid: " .. basename(path) .. " didn't load in time")
  end)
end

-- the soundfont for the next start, and the running fluidsynth if any
local function set_soundfont(path)
  prefs.soundfont = path
  write_prefs()
  load_soundfont(path)
end

local function set_gain(gain)
  prefs.gain = gain
  send(string.format("gain %.3f", gain))
end

------------------------------------------------------------------------
-- voices

local function p(i, name)
  return "nb_fluid_" .. name .. "_" .. i
end

-- voices a script is playing (in_use, declared above). only these push
-- their params to fluidsynth, so the other channels stay free for the
-- MIDI device.

local function has_params(i)
  return params and params.lookup[p(i, "kind")] ~= nil
end

local function owns(i)
  return in_use[i] and has_params(i)
end

local function cc(ch, num, val)
  send(string.format("cc %d %d %d", ch, num, util.clamp(math.floor(val), 0, 127)))
end

local function voice_cc(i, num, val)
  if owns(i) then
    cc(i - 1, num, val)
  end
end

local function apply_program(i)
  if not owns(i) then return end
  if params:get(p(i, "kind")) == 2 then
    local kit = gm.drum_kits[params:get(p(i, "kit"))]
    send(string.format("select %d %d 128 %d", i - 1, fluid.sfont_id, kit.prog))
  else
    send(string.format("select %d %d %d %d", i - 1, fluid.sfont_id,
      params:get(p(i, "bank")), params:get(p(i, "program")) - 1))
  end
end

local function apply_voice(i)
  if not owns(i) then return end
  apply_program(i)
  voice_cc(i, 7, params:get(p(i, "volume")))
  voice_cc(i, 10, (params:get(p(i, "pan")) + 1) * 64)
  voice_cc(i, 91, params:get(p(i, "reverb")))
  voice_cc(i, 93, params:get(p(i, "chorus")))
  send(string.format("pitch_bend_range %d %d", i - 1, params:get(p(i, "bend_range"))))
end

apply_all_voices = function()
  for i in pairs(in_use) do
    apply_voice(i)
  end
end

local function all_sound_off()
  for ch = 0, MAX_VOICES - 1 do
    cc(ch, 120, 0)
    cc(ch, 121, 0)
  end
end

local function update_visibility(i)
  local drums = params:get(p(i, "kind")) == 2
  params[drums and "hide" or "show"](params, p(i, "program"))
  params[drums and "hide" or "show"](params, p(i, "bank"))
  params[drums and "show" or "hide"](params, p(i, "kit"))
end

-- soundfont and gain, shared by all voices (and the MIDI device). Shown
-- while a fluid voice is in use; changing the soundfont swaps it in the
-- running fluidsynth, so soundfonts can be auditioned while playing.
-- Global settings like the mod menu's, so not saved in psets.
local SHARED = "nb_fluid_synth"
local shared_soundfonts = {}

local function has_shared_params()
  return params and params.lookup[SHARED .. "_soundfont"] ~= nil
end

local function update_shared_visibility()
  if not has_shared_params() then return end
  params[next(in_use) and "show" or "hide"](params, SHARED)
end

local function add_shared_params()
  shared_soundfonts = find_soundfonts()
  local names, current = {}, 1
  for idx, path in ipairs(shared_soundfonts) do
    names[idx] = basename(path)
    if path == prefs.soundfont then current = idx end
  end
  if #names == 0 then names = { "none found" } end
  params:add_group(SHARED, "fluid synth", 2)
  params:add_option(SHARED .. "_soundfont", "soundfont", names, current)
  params:set_action(SHARED .. "_soundfont", function(idx)
    local path = shared_soundfonts[idx]
    if path and path ~= prefs.soundfont then set_soundfont(path) end
  end)
  params:add_control(SHARED .. "_gain", "gain",
    controlspec.new(0, 2, "lin", 0.05, prefs.gain))
  params:set_action(SHARED .. "_gain", function(v)
    if v ~= prefs.gain then
      set_gain(v)
      write_prefs()
    end
  end)
  params:set_save(SHARED .. "_soundfont", false)
  params:set_save(SHARED .. "_gain", false)
  params:hide(SHARED)
end

-- the mod menu changed a shared setting, or fluidsynth (re)started, maybe
-- after an install added soundfonts the list doesn't have yet
sync_shared_params = function()
  if not has_shared_params() then return end
  local found = find_soundfonts()
  if #found > 0 then
    shared_soundfonts = found
    local param = params:lookup_param(SHARED .. "_soundfont")
    param.options = {}
    for idx, path in ipairs(found) do param.options[idx] = basename(path) end
    param.count = #found
  end
  for idx, path in ipairs(shared_soundfonts) do
    if path == prefs.soundfont then
      params:set(SHARED .. "_soundfont", idx, true)
    end
  end
  params:set(SHARED .. "_gain", prefs.gain, true)
end

local function add_fluid_params(i)
  -- nb adds players' params in name order, so fluid 1 comes first
  if i == 1 then add_shared_params() end
  params:add_group(p(i, "group"), "fluid " .. i, 9)
  params:add_option(p(i, "kind"), "kind", { "melodic", "drums" }, 1)
  params:set_action(p(i, "kind"), function(kind)
    update_visibility(i)
    _menu.rebuild_params()
    apply_program(i)
  end)
  params:add_option(p(i, "program"), "program", gm.program_options, 1)
  params:set_action(p(i, "program"), function() apply_program(i) end)
  params:add_number(p(i, "bank"), "bank", 0, 127, 0)
  params:set_action(p(i, "bank"), function() apply_program(i) end)
  params:add_option(p(i, "kit"), "kit", gm.drum_kit_options, 1)
  params:set_action(p(i, "kit"), function() apply_program(i) end)
  params:add_number(p(i, "volume"), "volume", 0, 127, 100)
  params:set_action(p(i, "volume"), function(v) voice_cc(i, 7, v) end)
  params:add_control(p(i, "pan"), "pan", controlspec.new(-1, 1, "lin", 0.01, 0))
  params:set_action(p(i, "pan"), function(v) voice_cc(i, 10, (v + 1) * 64) end)
  params:add_number(p(i, "reverb"), "reverb", 0, 127, 40)
  params:set_action(p(i, "reverb"), function(v) voice_cc(i, 91, v) end)
  params:add_number(p(i, "chorus"), "chorus", 0, 127, 0)
  params:set_action(p(i, "chorus"), function(v) voice_cc(i, 93, v) end)
  params:add_number(p(i, "bend_range"), "bend range", 1, 24, 2)
  params:set_action(p(i, "bend_range"), function(v)
    if owns(i) then
      send(string.format("pitch_bend_range %d %d", i - 1, v))
    end
  end)

  update_visibility(i)
  params:hide(p(i, "group"))
end

local function add_fluid_player(i)
  local ch = i - 1
  local player = {}

  function player:add_params()
    add_fluid_params(i)
  end

  function player:active()
    in_use[i] = true
    if self.name ~= nil then
      params:show(p(i, "group"))
      update_visibility(i)
      update_shared_visibility()
      _menu.rebuild_params()
    end
    if not fluid.out then
      start()
    else
      apply_voice(i)
    end
  end

  function player:inactive()
    in_use[i] = nil
    if self.name ~= nil then
      params:hide(p(i, "group"))
      update_shared_visibility()
      _menu.rebuild_params()
    end
  end

  function player:describe()
    return {
      name = "fluid " .. i,
      supports_bend = true,
      supports_slew = false,
      modulate_description = "mod wheel",
      note_mod_targets = {},
      voice_mod_targets = {},
      params = {},
    }
  end

  function player:note_on(note, vel, properties)
    if not fluid.out and not start() then return end
    if not in_use[i] then
      in_use[i] = true
      apply_voice(i)
    end
    local key = math.floor(note + 0.5) % 128
    local velocity = util.clamp(math.floor(vel * 127 + 0.5), 1, 127)
    send(string.format("noteon %d %d %d", ch, key, velocity))
  end

  function player:note_off(note)
    send(string.format("noteoff %d %d", ch, math.floor(note + 0.5) % 128))
  end

  -- fluidsynth bends the whole channel; amount is in semitones
  function player:pitch_bend(note, amount)
    local range = has_params(i) and params:get(p(i, "bend_range")) or 2
    local value = 8192 + math.floor(amount / range * 8192 + 0.5)
    send(string.format("pitch_bend %d %d", ch, util.clamp(value, 0, 16383)))
  end

  function player:modulate(val)
    cc(ch, 1, val * 127)
  end

  function player:stop_all()
    cc(ch, 123, 0)
  end

  if note_players == nil then
    note_players = {}
  end
  note_players["fluid " .. i] = player
end

------------------------------------------------------------------------
-- virtual MIDI device
--
-- "fluidsynth" shows up in SYSTEM > DEVICES > MIDI like a plugged-in
-- synth, so scripts with MIDI out (e.g. MIDI file players) can play all
-- 16 channels General MIDI style: programs, CCs, bend, drums on 10.

local MIDI_DEVICE_ID = "nb_fluid"

local function is_reset_sysex(data, first, last)
  local msg = table.concat(data, " ", first, last)
  return msg:match("^240 126 %d+ 9 1 247$") -- GM system on
    or msg:match("^240 65 %d+ 66 18 64 0 127 0 65 247$") -- GS reset
    or msg:match("^240 67 %d+ 76 0 0 126 0 247$") -- XG system on
end

local function midi_to_fluid(data)
  local i = 1
  while i <= #data do
    local status = data[i]
    if status == 0xF0 then
      local last = i
      while last < #data and data[last] ~= 0xF7 do
        last = last + 1
      end
      if is_reset_sysex(data, i, last) then
        send("reset")
        apply_all_voices()
      end
      i = last + 1
    elseif status >= 0xF0 then
      -- system common / realtime (clock, start, stop...): nothing to play
      i = i + ((status == 0xF2) and 3 or (status == 0xF1 or status == 0xF3) and 2 or 1)
    elseif status >= 0x80 then
      local kind, ch = status & 0xF0, status & 0x0F
      local a, b = data[i + 1] or 0, data[i + 2] or 0
      if kind == 0x90 and b > 0 then
        send(string.format("noteon %d %d %d", ch, a, b))
      elseif kind == 0x80 or kind == 0x90 then
        send(string.format("noteoff %d %d", ch, a))
      elseif kind == 0xB0 then
        send(string.format("cc %d %d %d", ch, a, b))
      elseif kind == 0xC0 then
        send(string.format("prog %d %d", ch, a))
      elseif kind == 0xE0 then
        send(string.format("pitch_bend %d %d", ch, (b << 7) | a))
      end
      -- (fluidsynth's shell has no aftertouch commands)
      i = i + ((kind == 0xC0 or kind == 0xD0) and 2 or 3)
    else
      i = i + 1
    end
  end
end

local function add_midi_device()
  if midi.devices[MIDI_DEVICE_ID] then return end
  local d = midi.new(MIDI_DEVICE_ID, "fluidsynth", nil)
  function d:send(data)
    if data.type then
      data = midi.to_data(data)
    end
    -- MIDI clock etc. shouldn't wake fluidsynth up
    if data[1] == nil or data[1] >= 0xF8 then return end
    if not fluid.out and not start() then return end
    midi_to_fluid(data)
  end
  -- there's no C-side device behind this one
  function d:clock_receive() end
  midi.devices[MIDI_DEVICE_ID] = d
  midi.update_devices()
  if midi.add then midi.add(d) end
end

------------------------------------------------------------------------
-- hooks

if not uninstalled() then
  util.make_dir(SOUNDFONT_DIR)
end

mod.hook.register("system_post_startup", "nb_fluid midi device", function()
  add_midi_device()
end)

mod.hook.register("script_pre_init", "nb_fluid pre init", function()
  read_prefs()
  for i in pairs(in_use) do
    in_use[i] = nil
  end
  for i = 1, prefs.voices do
    add_fluid_player(i)
  end
end)

mod.hook.register("script_post_cleanup", "nb_fluid post cleanup", function()
  all_sound_off()
end)

-- a script that re-routes audio makes norns restore the defaults on cleanup,
-- which drops our connections
mod.hook.register("audio_post_restore_default_routing", "nb_fluid routing", function()
  if fluid.out then
    connect_routes()
  end
end)

mod.hook.register("system_pre_shutdown", "nb_fluid shutdown", function()
  stop()
end)

------------------------------------------------------------------------
-- mod menu: soundfont, voice count, gain, setup, uninstall

local m = {
  item = 1,
  soundfonts = {},
  sf_index = 1,
  missing = {},
  -- "confirm" after the first K3 on uninstall, "done" once it finished
  uninstall = nil,
}
local ITEMS = { "soundfont", "voices", "gain", "setup", "uninstall" }

local function refresh_soundfonts()
  m.soundfonts = find_soundfonts()
  m.sf_index = 1
  for idx, path in ipairs(m.soundfonts) do
    if path == prefs.soundfont then
      m.sf_index = idx
    end
  end
end

function m.init()
  read_prefs()
  refresh_soundfonts()
  m.missing = get_deps():missing()
  m.uninstall = m.uninstall == "done" and "done" or nil
end

function m.deinit()
  write_prefs()
  fluid.failed = false
end

local function install()
  get_deps():ensure(nil, { on_done = function()
    m.missing = get_deps():missing()
    refresh_soundfonts()
    start_if_in_use()
  end })
end

-- undo the setup, then delete the mod itself; norns has to restart to
-- drop the mod from memory
local function uninstall()
  stop()
  setup.uninstall(function(ok)
    if ok then
      mod.set_enabled(mod_name, false, true)
      os.execute("rm -rf " .. setup.deps.platform.shell_quote(setup.CODE_DIR))
      m.uninstall = "done"
      print("nb_fluid: uninstalled; restart norns")
    else
      m.uninstall = nil
      m.missing = get_deps():missing()
    end
    mod.menu.redraw()
  end)
end

function m.key(n, z)
  if z ~= 1 then return end
  if n == 2 then
    if m.uninstall == "confirm" then
      m.uninstall = nil
      mod.menu.redraw()
    else
      mod.menu.exit()
    end
  elseif n == 3 and m.uninstall ~= "done" then
    local item = ITEMS[m.item]
    if item == "setup" then
      install()
    elseif item == "uninstall" then
      if m.uninstall == "confirm" then
        uninstall()
      else
        m.uninstall = "confirm"
        mod.menu.redraw()
      end
    end
  end
end

function m.enc(n, d)
  if m.uninstall then return end
  if n == 2 then
    m.item = util.clamp(m.item + d, 1, #ITEMS)
  elseif n == 3 then
    local item = ITEMS[m.item]
    if item == "soundfont" and #m.soundfonts > 0 then
      local idx = util.clamp(m.sf_index + d, 1, #m.soundfonts)
      if idx ~= m.sf_index then
        m.sf_index = idx
        set_soundfont(m.soundfonts[idx])
        sync_shared_params()
      end
    elseif item == "voices" then
      prefs.voices = util.clamp(prefs.voices + d, 1, MAX_VOICES)
    elseif item == "gain" then
      set_gain(util.clamp(prefs.gain + d * 0.05, 0, 2))
      sync_shared_params()
    end
  end
  mod.menu.redraw()
end

local function draw_center(lines)
  for idx, line in ipairs(lines) do
    screen.level(idx == 1 and 15 or 4)
    screen.move(64, 22 + idx * 10)
    screen.text_center(line)
  end
end

function m.redraw()
  screen.clear()
  screen.level(4)
  screen.move(0, 10)
  screen.text("MODS / NB_FLUID")
  if m.uninstall == "confirm" then
    draw_center({ "uninstall nb_fluid?", "removes its service, the", "packages it installed", "and the mod. K3 yes" })
    screen.update()
    return
  elseif m.uninstall == "done" then
    draw_center({ "uninstalled", "restart norns" })
    screen.update()
    return
  end
  local values = {
    #m.soundfonts > 0 and basename(prefs.soundfont) or "none found",
    prefs.voices,
    string.format("%.2f", prefs.gain),
    #m.missing == 0 and "ok" or (#m.missing .. " missing, K3"),
    "K3",
  }
  -- five rows from y=20; the hint takes the bottom line
  local first = util.clamp(m.item - 3, 0, #ITEMS - 4)
  for row = 1, 4 do
    local idx = first + row
    local y = 10 + row * 10
    screen.level(idx == m.item and 15 or 4)
    screen.move(0, y)
    screen.text(ITEMS[idx])
    screen.move(127, y)
    local value = tostring(values[idx])
    if #value > 18 then
      value = value:sub(1, 17) .. "~"
    end
    screen.text_right(value)
  end
  local hint = ({
    soundfont = "soundfont: also in PARAMS",
    voices = "voices apply on next script load",
  })[ITEMS[m.item]]
  if hint then
    screen.level(2)
    screen.move(0, 62)
    screen.text(hint)
  end
  screen.update()
end

mod.menu.register(mod_name, m)
