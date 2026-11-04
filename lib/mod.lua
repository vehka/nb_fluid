-- nb_fluid
-- fluidsynth as nb voices: General MIDI on norns via soundfonts.
--
-- fluidsynth runs as a system service (nb-fluid.service, see lib/setup.lua)
-- that the mod starts on demand and feeds shell commands through a FIFO.
-- its JACK outputs are wired into crone's engine inputs, so it follows
-- the ENGINE level and the norns reverb / tape like any engine would.
-- each nb voice "fluid N" plays MIDI channel N, with either soundfont.
-- two MIDI devices, "fluidsynth" and "fluidsynth 2", play soundfont 1 and
-- 2 on fluidsynth channels 0-15 and 16-31.

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
-- each MIDI device has 16; service.sh starts fluidsynth with all of them
local DEVICE_CHANNELS = 16
local CHANNELS = 2 * DEVICE_CHANNELS
local POLYPHONY = 64
-- norns runs JACK at 48k; fluidsynth's reverb can't follow a later rate change
local SAMPLE_RATE = 48000
-- what start() can't do without; the rest is offered alongside them
local REQUIRED = { "fluidsynth", "service" }

local prefs = {
  voices = 4,
  soundfont = nil,
  -- nil: soundfont 2 is the same as soundfont 1
  soundfont2 = nil,
  gain = 0.5,
}

local fluid = {
  -- the FIFO's write end, while fluidsynth runs
  out = nil,
  pid = nil,
  started_at = 0,
  checked_at = 0,
  -- the soundfonts loaded in slots 1 and 2: { id, path, presets, first },
  -- see the soundfonts section. fluidsynth numbers soundfonts per process,
  -- counting every load.
  sf = { {}, {} },
  -- a soundfont load or preset listing in progress
  job = nil,
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
  fluid.job = nil
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
local reset_chans
local list_presets
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
  -- after an ssh logout, logind may have removed JACK's shared memory:
  -- running clients keep working, but fluidsynth could never connect
  if d:jack_files_missing() then
    print("nb_fluid: JACK's files in /dev/shm are gone (an ssh logout"
      .. " removes them on older norns); reboot to play fluid voices")
    return false
  end
  if prefs.soundfont == nil or not util.file_exists(prefs.soundfont) then
    prefs.soundfont = find_soundfonts()[1]
  end
  if prefs.soundfont == nil then
    print("nb_fluid: no soundfont found; put a .sf2 in " .. SOUNDFONT_DIR)
    return false
  end
  if prefs.soundfont2 and not util.file_exists(prefs.soundfont2) then
    prefs.soundfont2 = nil
  end

  setup.write_env {
    soundfont = prefs.soundfont, gain = prefs.gain,
    sample_rate = SAMPLE_RATE, polyphony = POLYPHONY, jack_id = JACK_ID,
  }
  os.remove(setup.PIDFILE)
  -- the soundfont jobs read fluidsynth's answers from the log, so nothing
  -- from an earlier run may be left in it
  os.remove(LOG_FILE)
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
  -- the soundfont on fluidsynth's command line is its number 1
  fluid.sf = { { id = 1, path = prefs.soundfont }, {} }
  reset_chans()
  fluid.failed = false
  print("nb_fluid: started fluidsynth with " .. basename(prefs.soundfont))
  sync_shared_params()
  connect_when_ready()
  -- commands queue in the FIFO until the soundfont has loaded
  apply_all_voices()
  -- then soundfont 2 loads, if there is one
  list_presets(1)
  return true
end

local function stop()
  close_fifo()
  setup.priv("systemctl stop " .. setup.UNIT)
end

------------------------------------------------------------------------
-- soundfonts
--
-- Two soundfonts can be loaded at once. Slot 1 plays the "fluidsynth" MIDI
-- device (channels 0-15), slot 2 the "fluidsynth 2" device (channels
-- 16-31), and each nb voice picks one. With no second soundfont, slot 2
-- plays slot 1's.
--
-- fluidsynth's own program change searches every loaded soundfont, so
-- programs are always chosen with "select", which names the soundfont.
-- Its fallbacks for a missing preset are redone here, from each
-- soundfont's preset list ("inst"). Loads and unloads pass reset 0, so
-- fluidsynth doesn't re-pick every channel's program by itself.

local function slot_of(ch)
  return ch < DEVICE_CHANNELS and 1 or 2
end

-- the file a slot should have loaded; nil for slot 2: same as slot 1
local function wanted(slot)
  if slot == 1 then return prefs.soundfont end
  if prefs.soundfont2 ~= prefs.soundfont then return prefs.soundfont2 end
end

-- the loaded soundfont a slot plays
local function playing(slot)
  local sf = fluid.sf[slot]
  return sf.id and sf or fluid.sf[1]
end

local function has_preset(sf, bank, prog)
  return sf.presets[bank * 128 + prog] ~= nil
end

-- The preset to play for a bank and program, with fluidsynth's fallbacks:
-- drums try the same program in bank 128, then the standard kit; melodic
-- programs try bank 0, then its first program, then the soundfont's first
-- preset. nil when there's nothing to play. Without a preset list (not
-- read yet), fluidsynth gets to try the bank and program as they are.
local function find_preset(sf, bank, prog, drums)
  if not sf.presets then return bank, prog end
  local tries = drums and { { bank, prog }, { 128, prog }, { 128, 0 } }
    or { { bank, prog }, { 0, prog }, { 0, 0 }, sf.first }
  for _, t in ipairs(tries) do
    if has_preset(sf, t[1], t[2]) then return t[1], t[2] end
  end
end

-- what each channel's MIDI asked for: bank select (CC 0) and program
local chans = {}

local function reset_chan(ch)
  chans[ch] = { bank = 0, prog = 0 }
end

reset_chans = function()
  for ch = 0, CHANNELS - 1 do reset_chan(ch) end
end
reset_chans()

-- Point a channel at its device's soundfont, at the program its MIDI
-- asked for. Channel 10 of each device is the drum channel.
local function apply_channel(ch, quiet)
  local sf = playing(slot_of(ch))
  if not sf.id then return end
  local drums = ch % DEVICE_CHANNELS == 9
  local want_bank = (drums and 128 or 0) + chans[ch].bank
  local want_prog = chans[ch].prog
  local bank, prog = find_preset(sf, want_bank, want_prog, drums)
  if bank == nil then
    if not quiet then
      print(string.format("nb_fluid: %s has nothing to play for bank %d"
        .. " program %d (channel %d)", basename(sf.path), want_bank, want_prog,
        ch))
    end
    -- program 128 means none: the channel goes silent
    send(string.format("prog %d 128", ch))
    return
  end
  if not quiet and (bank ~= want_bank or prog ~= want_prog) then
    print(string.format("nb_fluid: %s has no bank %d program %d, playing"
      .. " %d:%d (channel %d)", basename(sf.path), want_bank, want_prog,
      bank, prog, ch))
  end
  send(string.format("select %d %d %d %d", ch, sf.id, bank, prog))
end

-- after a soundfont change: every channel, then the voices on top
local function apply_all()
  for ch = 0, CHANNELS - 1 do apply_channel(ch, true) end
  apply_all_voices()
end

-- A job loads a soundfont into a slot and reads its preset list, both
-- from fluidsynth's answers in the log: "loaded SoundFont has ID n", then
-- the "inst n" lines up to an echoed marker. fluid.job is { slot, path,
-- offset, started, loaded, id, presets, first }; id is known once the
-- soundfont has loaded. One job runs at a time.

local sync_soundfonts

local function marker(id)
  return "nb_fluid_presets_" .. id
end

local function request_presets(job)
  job.offset = file_size(LOG_FILE)
  send("inst " .. job.id)
  send("echo " .. marker(job.id))
end

-- true once the job's soundfont is loaded and its presets are read
local function step_job(job)
  local out = read_from(LOG_FILE, job.offset)
  if not job.id then
    local id = out:match("loaded SoundFont has ID (%d+)")
    if id then
      job.id = tonumber(id)
      request_presets(job)
    elseif out:match("failed to load the SoundFont") then
      return true
    end
    return false
  end
  local presets, first, mark = {}, nil, marker(job.id)
  -- whole lines only; the shell's "> " prompt may come first
  for raw in out:gmatch("([^\n]*)\n") do
    local line = raw:gsub("^[> ]+", "")
    if line == mark then
      job.presets, job.first = presets, first
      return true
    end
    local bank, prog = line:match("^(%d+)%-(%d+) ")
    if bank then
      bank, prog = tonumber(bank), tonumber(prog)
      presets[bank * 128 + prog] = true
      first = first or { bank, prog }
    end
  end
  return false
end

local function finish_job(job)
  fluid.job = nil
  local sf = fluid.sf[job.slot]
  if not job.id then
    sf.failed = job.path
    print("nb_fluid: couldn't load " .. basename(job.path) .. ", see " .. LOG_FILE)
  else
    if not job.presets then
      print("nb_fluid: couldn't read the presets of " .. basename(job.path))
    end
    local old = sf.id ~= job.id and sf.id or nil
    fluid.sf[job.slot] = {
      id = job.id, path = job.path, presets = job.presets, first = job.first,
    }
    apply_all()
    if old then send("unload " .. old .. " 0") end
    if job.loaded then
      print("nb_fluid: soundfont " .. job.slot .. " is now " .. basename(job.path))
    end
  end
  sync_soundfonts()
end

-- Polls the log for the job. Started again in script_pre_init, since
-- loading a script cancels the mod's clocks too.
local function watch_job()
  local job = fluid.job
  if not job then return end
  local token = {}
  job.watcher = token
  clock.run(function()
    while fluid.job == job and job.watcher == token do
      -- big soundfonts take a while on a pi
      if step_job(job) or util.time() - job.started > 60 then
        finish_job(job)
        return
      end
      clock.sleep(0.25)
    end
  end)
end

-- the presets of the soundfont fluidsynth started with
list_presets = function(slot)
  local sf = fluid.sf[slot]
  fluid.job = { slot = slot, path = sf.path, id = sf.id, started = util.time() }
  request_presets(fluid.job)
  -- the log was removed before the start; fluidsynth writes a new one
  fluid.job.offset = 0
  watch_job()
end

-- Brings the loaded soundfonts in line with the prefs, one load at a
-- time. Notes keep playing on the old soundfont until the new one has
-- loaded; then the channels move over, and the old one is unloaded.
sync_soundfonts = function()
  if not fluid.out or fluid.job then return end
  for slot = 1, 2 do
    local sf, path = fluid.sf[slot], wanted(slot)
    if path ~= sf.path and (path == nil or path ~= sf.failed) then
      if path == nil then
        -- slot 2 back to the same as slot 1
        local old = sf.id
        fluid.sf[slot] = {}
        apply_all()
        send("unload " .. old .. " 0")
        print("nb_fluid: soundfont 2 is now the same as soundfont 1")
      elseif util.file_exists(path) then
        fluid.job = {
          slot = slot, path = path, offset = file_size(LOG_FILE),
          started = util.time(), loaded = true,
        }
        send("load " .. shell_path(path) .. " 0")
        watch_job()
        return
      end
    end
  end
end

-- the soundfont for the next start, and the running fluidsynth if any;
-- nil for slot 2: the same as slot 1
local function set_soundfont(slot, path)
  if slot == 1 then
    prefs.soundfont = path
  else
    prefs.soundfont2 = path
  end
  write_prefs()
  sync_soundfonts()
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

-- A preset the soundfont doesn't have isn't selected: the voice keeps
-- playing what it had, rather than jumping to a fallback while someone
-- scrolls through bank numbers.
local function apply_program(i)
  if not owns(i) then return end
  local sf = playing(params:get(p(i, "soundfont")))
  if not sf.id then return end
  local bank, prog
  if params:get(p(i, "kind")) == 2 then
    bank, prog = 128, gm.drum_kits[params:get(p(i, "kit"))].prog
  else
    bank, prog = params:get(p(i, "bank")), params:get(p(i, "program")) - 1
  end
  if sf.presets and not has_preset(sf, bank, prog) then
    print(string.format("nb_fluid: fluid %d: %s has no bank %d program %d",
      i, basename(sf.path), bank, prog))
    return
  end
  send(string.format("select %d %d %d %d", i - 1, sf.id, bank, prog))
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
  for ch = 0, CHANNELS - 1 do
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

-- the soundfonts and gain, shared by all voices (and the MIDI devices).
-- Shown while a fluid voice is in use; changing a soundfont swaps it in
-- the running fluidsynth, so soundfonts can be auditioned while playing.
-- Global settings like the mod menu's, so not saved in psets.
local SHARED = "nb_fluid_synth"
local SAME = "same as 1"
local shared_soundfonts = {}

local function has_shared_params()
  return params and params.lookup[SHARED .. "_soundfont"] ~= nil
end

local function update_shared_visibility()
  if not has_shared_params() then return end
  params[next(in_use) and "show" or "hide"](params, SHARED)
end

-- the option lists for soundfont 1, and soundfont 2 ("same as 1" first)
local function soundfont_options(found)
  local names, names2 = {}, { SAME }
  for idx, path in ipairs(found) do
    names[idx] = basename(path)
    names2[idx + 1] = names[idx]
  end
  if #names == 0 then names = { "none found" } end
  return names, names2
end

-- which option is each slot's soundfont
local function soundfont_indexes(found)
  local idx1, idx2 = 1, 1
  for idx, path in ipairs(found) do
    if path == prefs.soundfont then idx1 = idx end
    if path == prefs.soundfont2 then idx2 = idx + 1 end
  end
  return idx1, idx2
end

local function add_shared_params()
  shared_soundfonts = find_soundfonts()
  local names, names2 = soundfont_options(shared_soundfonts)
  local idx1, idx2 = soundfont_indexes(shared_soundfonts)
  params:add_group(SHARED, "fluid synth", 3)
  params:add_option(SHARED .. "_soundfont", "soundfont", names, idx1)
  params:set_action(SHARED .. "_soundfont", function(idx)
    local path = shared_soundfonts[idx]
    if path and path ~= prefs.soundfont then set_soundfont(1, path) end
  end)
  params:add_option(SHARED .. "_soundfont2", "soundfont 2", names2, idx2)
  params:set_action(SHARED .. "_soundfont2", function(idx)
    local path = shared_soundfonts[idx - 1]
    if path ~= prefs.soundfont2 then set_soundfont(2, path) end
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
  params:set_save(SHARED .. "_soundfont2", false)
  params:set_save(SHARED .. "_gain", false)
  params:hide(SHARED)
end

-- the mod menu changed a shared setting, or fluidsynth (re)started, maybe
-- after an install added soundfonts the lists don't have yet
sync_shared_params = function()
  if not has_shared_params() then return end
  local found = find_soundfonts()
  if #found > 0 then
    shared_soundfonts = found
    local names, names2 = soundfont_options(found)
    for id, options in pairs { _soundfont = names, _soundfont2 = names2 } do
      local param = params:lookup_param(SHARED .. id)
      param.options = options
      param.count = #options
    end
  end
  local idx1, idx2 = soundfont_indexes(shared_soundfonts)
  params:set(SHARED .. "_soundfont", idx1, true)
  params:set(SHARED .. "_soundfont2", idx2, true)
  params:set(SHARED .. "_gain", prefs.gain, true)
end

local function add_fluid_params(i)
  -- nb adds players' params in name order, so fluid 1 comes first
  if i == 1 then add_shared_params() end
  params:add_group(p(i, "group"), "fluid " .. i, 10)
  params:add_option(p(i, "soundfont"), "soundfont", { "1", "2" }, 1)
  params:set_action(p(i, "soundfont"), function() apply_program(i) end)
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
-- virtual MIDI devices
--
-- "fluidsynth" and "fluidsynth 2" show up in SYSTEM > DEVICES > MIDI like
-- plugged-in synths, so scripts with MIDI out (e.g. MIDI file players) can
-- play 16 channels each General MIDI style: programs, CCs, bend, drums on
-- 10. The first plays soundfont 1 on fluidsynth channels 0-15, the second
-- soundfont 2 on channels 16-31.

local DEVICES = {
  { id = "nb_fluid", name = "fluidsynth" },
  { id = "nb_fluid_2", name = "fluidsynth 2" },
}

local function is_reset_sysex(data, first, last)
  local msg = table.concat(data, " ", first, last)
  return msg:match("^240 126 %d+ 9 1 247$") -- GM system on
    or msg:match("^240 65 %d+ 66 18 64 0 127 0 65 247$") -- GS reset
    or msg:match("^240 67 %d+ 76 0 0 126 0 247$") -- XG system on
end

-- A GM / GS / XG reset of one device's channels. fluidsynth's own "reset"
-- would reset the other device too, and pick programs from either
-- soundfont. This restores what its reset does to a channel.
local function reset_device(base)
  for ch = base, base + DEVICE_CHANNELS - 1 do
    cc(ch, 120, 0) -- all sound off
    cc(ch, 121, 0) -- reset all controllers
    -- what CC 121 leaves alone: volume, pan, balance, effect sends,
    -- sound controllers
    cc(ch, 7, 100)
    cc(ch, 10, 64)
    cc(ch, 8, 64)
    for num = 91, 95 do cc(ch, num, 0) end
    for num = 70, 79 do cc(ch, num, 64) end
    send(string.format("pitch_bend_range %d 2", ch))
    reset_chan(ch)
    apply_channel(ch, true)
  end
  apply_all_voices()
end

local function midi_to_fluid(data, base)
  local i = 1
  while i <= #data do
    local status = data[i]
    if status == 0xF0 then
      local last = i
      while last < #data and data[last] ~= 0xF7 do
        last = last + 1
      end
      if is_reset_sysex(data, i, last) then
        reset_device(base)
      end
      i = last + 1
    elseif status >= 0xF0 then
      -- system common / realtime (clock, start, stop...): nothing to play
      i = i + ((status == 0xF2) and 3 or (status == 0xF1 or status == 0xF3) and 2 or 1)
    elseif status >= 0x80 then
      local kind, ch = status & 0xF0, base + (status & 0x0F)
      local a, b = data[i + 1] or 0, data[i + 2] or 0
      if kind == 0x90 and b > 0 then
        send(string.format("noteon %d %d %d", ch, a, b))
      elseif kind == 0x80 or kind == 0x90 then
        send(string.format("noteoff %d %d", ch, a))
      elseif kind == 0xB0 then
        -- bank select is kept for the next program change; CC 32 is ignored
        if a == 0 then
          chans[ch].bank = b
        elseif a ~= 32 then
          send(string.format("cc %d %d %d", ch, a, b))
        end
      elseif kind == 0xC0 then
        chans[ch].prog = a
        apply_channel(ch)
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

local function add_midi_device(n)
  local def = DEVICES[n]
  if midi.devices[def.id] then return end
  local base = (n - 1) * DEVICE_CHANNELS
  local d = midi.new(def.id, def.name, nil)
  function d:send(data)
    if data.type then
      data = midi.to_data(data)
    end
    -- MIDI clock etc. shouldn't wake fluidsynth up
    if data[1] == nil or data[1] >= 0xF8 then return end
    if not fluid.out and not start() then return end
    midi_to_fluid(data, base)
  end
  -- there's no C-side device behind this one
  function d:clock_receive() end
  midi.devices[def.id] = d
  midi.update_devices()
  if midi.add then midi.add(d) end
end

------------------------------------------------------------------------
-- hooks

if not uninstalled() then
  util.make_dir(SOUNDFONT_DIR)
end

mod.hook.register("system_post_startup", "nb_fluid midi device", function()
  for n in ipairs(DEVICES) do
    add_midi_device(n)
  end
end)

mod.hook.register("script_pre_init", "nb_fluid pre init", function()
  -- loading the script cancelled the clock of a soundfont load
  watch_job()
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
-- mod menu: soundfonts, voice count, gain, setup, uninstall

local m = {
  item = 1,
  soundfonts = {},
  sf_index = 1,
  -- 0: the same as soundfont 1
  sf2_index = 0,
  missing = {},
  -- "confirm" after the first K3 on uninstall, "done" once it finished
  uninstall = nil,
}
local ITEMS = { "soundfont", "soundfont 2", "voices", "gain", "setup", "uninstall" }

local function refresh_soundfonts()
  m.soundfonts = find_soundfonts()
  m.sf_index, m.sf2_index = 1, 0
  for idx, path in ipairs(m.soundfonts) do
    if path == prefs.soundfont then
      m.sf_index = idx
    end
    if path == prefs.soundfont2 then
      m.sf2_index = idx
    end
  end
end

function m.init()
  read_prefs()
  refresh_soundfonts()
  m.missing = get_deps():missing()
  m.jack_gone = get_deps():jack_files_missing()
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
        set_soundfont(1, m.soundfonts[idx])
        sync_shared_params()
      end
    elseif item == "soundfont 2" and #m.soundfonts > 0 then
      local idx = util.clamp(m.sf2_index + d, 0, #m.soundfonts)
      if idx ~= m.sf2_index then
        m.sf2_index = idx
        set_soundfont(2, m.soundfonts[idx])
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
    prefs.soundfont2 and basename(prefs.soundfont2) or SAME,
    prefs.voices,
    string.format("%.2f", prefs.gain),
    #m.missing > 0 and (#m.missing .. " missing, K3")
      or (m.jack_gone and "reboot needed" or "ok"),
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
    -- the longer the label, the less room for the value
    local room = math.min(18, 27 - #ITEMS[idx])
    if #value > room then
      value = value:sub(1, room - 1) .. "~"
    end
    screen.text_right(value)
  end
  local hint = ({
    soundfont = "soundfont: also in PARAMS",
    ["soundfont 2"] = "for the fluidsynth 2 device",
    voices = "voices apply on next script load",
    setup = m.jack_gone and #m.missing == 0 and "JACK's files are gone" or nil,
  })[ITEMS[m.item]]
  if hint then
    screen.level(2)
    screen.move(0, 62)
    screen.text(hint)
  end
  screen.update()
end

mod.menu.register(mod_name, m)
