-- nb_fluid
-- fluidsynth as nb voices: General MIDI on norns via soundfonts.
--
-- fluidsynth runs as a child process fed shell commands over a pipe.
-- its JACK outputs are wired into crone's engine inputs, so it follows
-- the ENGINE level and the norns reverb / tape like any engine would.
-- each nb voice "fluid N" plays MIDI channel N.

local mod = require 'core/mods'

local mod_name = mod.this_name or "nb_fluid"
local gm = require(mod_name .. '/lib/gm')

local DATA_DIR = _path.data .. "nb_fluid/"
local PREFS_FILE = DATA_DIR .. "prefs.data"
local LOG_FILE = "/tmp/nb_fluid.log"
local JACK_ID = "nb_fluid"
local SOUNDFONT_DIR = DATA_DIR .. "soundfonts/"
-- the engine inputs; SuperCollider uses the same pair
local ROUTES = {
  { JACK_ID .. ":left", "crone:input_5" },
  { JACK_ID .. ":right", "crone:input_6" },
}
local MAX_VOICES = 16
local POLYPHONY = 64
-- norns runs JACK at 48k; fluidsynth's reverb can't follow a later rate change
local SAMPLE_RATE = 48000
-- fluidsynth numbers soundfonts from 1 per process; we only load one.
local SFONT_ID = 1

local prefs = {
  voices = 4,
  soundfont = nil,
  gain = 0.5,
}

local fluid = {
  pipe = nil,
  available = nil,
  -- set when starting failed, so note_on doesn't retry on every note
  failed = false,
}

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

local function write_prefs()
  tab.save(prefs, PREFS_FILE)
end

local function find_soundfonts()
  local found = {}
  for _, name in ipairs(util.scandir(SOUNDFONT_DIR)) do
    if name:lower():match("%.sf[23]$") then
      table.insert(found, SOUNDFONT_DIR .. name)
    end
  end
  return found
end

local function basename(path)
  return path and path:match("([^/]+)$") or "none"
end

------------------------------------------------------------------------
-- fluidsynth process

local function send(line)
  if fluid.pipe then
    fluid.pipe:write(line, "\n")
    fluid.pipe:flush()
  end
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
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
  clock.run(function()
    for _ = 1, 120 do
      if fluid.pipe == nil then
        return
      end
      if jack_port_exists(ROUTES[1][1]) then
        connect_routes()
        return
      end
      clock.sleep(0.25)
    end
    print("nb_fluid: fluidsynth JACK ports never appeared, see " .. LOG_FILE)
  end)
end

local apply_all_voices

local function start()
  if fluid.pipe then
    return true
  end
  if fluid.failed then
    return false
  end
  fluid.failed = true
  if fluid.available == nil then
    fluid.available = os.execute("command -v fluidsynth >/dev/null 2>&1") == true
  end
  if not fluid.available then
    print("nb_fluid: fluidsynth not found; install it (sudo apt install fluidsynth)")
    return false
  end
  if prefs.soundfont == nil or not util.file_exists(prefs.soundfont) then
    prefs.soundfont = find_soundfonts()[1]
  end
  if prefs.soundfont == nil then
    print("nb_fluid: no soundfont found; put a .sf2 in " .. SOUNDFONT_DIR)
    return false
  end

  -- `cat` keeps draining the pipe if fluidsynth dies, so writes never
  -- SIGPIPE matron. closing the pipe (EOF) makes both exit.
  local cmd = string.format(
    "fluidsynth -a jack -n -r %d -o audio.jack.id=%s -o audio.jack.autoconnect=0"
      .. " -o synth.polyphony=%d -o synth.dynamic-sample-loading=1 -g %.3f %s"
      .. " >%s 2>&1; cat >/dev/null",
    SAMPLE_RATE, JACK_ID, POLYPHONY, prefs.gain, shell_quote(prefs.soundfont), LOG_FILE)
  fluid.pipe = io.popen(cmd, "w")
  if fluid.pipe == nil then
    print("nb_fluid: failed to start fluidsynth")
    return false
  end
  fluid.failed = false
  print("nb_fluid: started fluidsynth with " .. basename(prefs.soundfont))
  connect_when_ready()
  -- commands queue in the pipe until the soundfont has loaded
  apply_all_voices()
  return true
end

local function stop()
  if fluid.pipe then
    fluid.pipe:close()
    fluid.pipe = nil
  end
end

------------------------------------------------------------------------
-- voices

local function p(i, name)
  return "nb_fluid_" .. name .. "_" .. i
end

local function has_params(i)
  return params and params.lookup[p(i, "kind")] ~= nil
end

local function cc(ch, num, val)
  send(string.format("cc %d %d %d", ch, num, util.clamp(math.floor(val), 0, 127)))
end

local function apply_program(i)
  if not has_params(i) then return end
  if params:get(p(i, "kind")) == 2 then
    local kit = gm.drum_kits[params:get(p(i, "kit"))]
    send(string.format("select %d %d 128 %d", i - 1, SFONT_ID, kit.prog))
  else
    send(string.format("select %d %d %d %d", i - 1, SFONT_ID,
      params:get(p(i, "bank")), params:get(p(i, "program")) - 1))
  end
end

local function apply_voice(i)
  if not has_params(i) then return end
  local ch = i - 1
  apply_program(i)
  cc(ch, 7, params:get(p(i, "volume")))
  cc(ch, 10, (params:get(p(i, "pan")) + 1) * 64)
  cc(ch, 91, params:get(p(i, "reverb")))
  cc(ch, 93, params:get(p(i, "chorus")))
  send(string.format("pitch_bend_range %d %d", ch, params:get(p(i, "bend_range"))))
end

apply_all_voices = function()
  for i = 1, MAX_VOICES do
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

local function add_fluid_params(i)
  local ch = i - 1
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
  params:set_action(p(i, "volume"), function(v) cc(ch, 7, v) end)
  params:add_control(p(i, "pan"), "pan", controlspec.new(-1, 1, "lin", 0.01, 0))
  params:set_action(p(i, "pan"), function(v) cc(ch, 10, (v + 1) * 64) end)
  params:add_number(p(i, "reverb"), "reverb", 0, 127, 40)
  params:set_action(p(i, "reverb"), function(v) cc(ch, 91, v) end)
  params:add_number(p(i, "chorus"), "chorus", 0, 127, 0)
  params:set_action(p(i, "chorus"), function(v) cc(ch, 93, v) end)
  params:add_number(p(i, "bend_range"), "bend range", 1, 24, 2)
  params:set_action(p(i, "bend_range"), function(v)
    send(string.format("pitch_bend_range %d %d", ch, v))
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
    if self.name ~= nil then
      params:show(p(i, "group"))
      update_visibility(i)
      _menu.rebuild_params()
    end
    if not fluid.pipe then
      start()
    else
      apply_voice(i)
    end
  end

  function player:inactive()
    if self.name ~= nil then
      params:hide(p(i, "group"))
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
    if not fluid.pipe and not start() then return end
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
-- hooks

util.make_dir(SOUNDFONT_DIR)

mod.hook.register("script_pre_init", "nb_fluid pre init", function()
  read_prefs()
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
  if fluid.pipe then
    connect_routes()
  end
end)

mod.hook.register("system_pre_shutdown", "nb_fluid shutdown", function()
  stop()
end)

------------------------------------------------------------------------
-- mod menu: soundfont, voice count, gain

local m = {
  item = 1,
  soundfonts = {},
  sf_index = 1,
  initial_soundfont = nil,
}
local ITEMS = { "soundfont", "voices", "gain" }

function m.init()
  read_prefs()
  m.soundfonts = find_soundfonts()
  m.sf_index = 1
  for idx, path in ipairs(m.soundfonts) do
    if path == prefs.soundfont then
      m.sf_index = idx
    end
  end
  m.initial_soundfont = prefs.soundfont
end

function m.deinit()
  write_prefs()
  fluid.failed = false
  if fluid.pipe and prefs.soundfont ~= m.initial_soundfont then
    stop()
    start()
  end
end

function m.key(n, z)
  if n == 2 and z == 1 then
    mod.menu.exit()
  end
end

function m.enc(n, d)
  if n == 2 then
    m.item = util.clamp(m.item + d, 1, #ITEMS)
  elseif n == 3 then
    local item = ITEMS[m.item]
    if item == "soundfont" and #m.soundfonts > 0 then
      m.sf_index = util.clamp(m.sf_index + d, 1, #m.soundfonts)
      prefs.soundfont = m.soundfonts[m.sf_index]
    elseif item == "voices" then
      prefs.voices = util.clamp(prefs.voices + d, 1, MAX_VOICES)
    elseif item == "gain" then
      prefs.gain = util.clamp(prefs.gain + d * 0.05, 0, 2)
      send(string.format("gain %.3f", prefs.gain))
    end
  end
  mod.menu.redraw()
end

function m.redraw()
  screen.clear()
  screen.level(4)
  screen.move(0, 10)
  screen.text("MODS / NB_FLUID")
  local values = {
    #m.soundfonts > 0 and basename(prefs.soundfont) or "none found",
    prefs.voices,
    string.format("%.2f", prefs.gain),
  }
  for idx, label in ipairs(ITEMS) do
    local y = 20 + idx * 10
    screen.level(idx == m.item and 15 or 4)
    screen.move(0, y)
    screen.text(label)
    screen.move(127, y)
    local value = tostring(values[idx])
    if #value > 18 then
      value = value:sub(1, 17) .. "~"
    end
    screen.text_right(value)
  end
  screen.level(2)
  screen.move(0, 62)
  screen.text("voices apply on next script load")
  screen.update()
end

mod.menu.register(mod_name, m)
