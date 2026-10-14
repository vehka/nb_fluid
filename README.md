# nb_fluid

An [nb](https://llllllll.co/t/n-b-et-al-v0-1/60374) voice mod for norns that
plays [FluidSynth](https://www.fluidsynth.org/) on norns. It loads any
SoundFont (`.sf2` / `.sf3`); with a General MIDI soundfont you get the full
GM instrument set and drum kits.

Two ways in, both driving one shared FluidSynth instance:

- **nb voices** `fluid 1` … `fluid N`: each is one MIDI channel. Pick a
  program by its GM name, or switch a voice to drums and choose a drum kit.
- **a virtual MIDI device** called `fluidsynth`: a 16-channel General MIDI
  synth for any script with MIDI out, e.g. a MIDI file player. The song
  picks its own instruments with program changes, and drums are on
  channel 10.

## Requirements

- norns with the [nb](https://github.com/sixolet/nb) library (used by the
  script, not installed separately)
- `fluidsynth` built with JACK support, and a system service that runs it.
  The mod installs both itself, see below.

## Install

```
;install https://github.com/vehka/nb_fluid
```

Then enable it in **SYSTEM > MODS**, and restart norns.

The first time a script selects a `fluid` voice (or sends to the
`fluidsynth` MIDI device), the mod opens an install screen listing what is
missing. K3 installs it, K2 cancels. You can also open it from
**SYSTEM > MODS > NB_FLUID > setup**. It installs:

- **FluidSynth**: `apt install --no-install-recommends fluidsynth`. Without
  recommends, so it skips `qsynth`, a Qt GUI that is of no use on norns. The
  package brings in a small GM soundfont (TimGM6mb), so it plays right away.
- **fluidsynth user service off**: the package enables a `fluidsynth`
  systemd user service for all users. It would never run on norns, but it
  is disabled (`systemctl --global disable fluidsynth.service`) so it can't
  start a second fluidsynth next to the mod's own.
- **nb-fluid service**: `/etc/systemd/system/nb-fluid.service`, which runs
  fluidsynth for the mod (see [How it works](#how-it-works)). It never
  starts at boot, only when the mod needs it.
- **default soundfont**: a link to the system GM soundfont in the
  soundfont folder.

Anything already in place is skipped. Installing uses `sudo`, which norns
has without a password. The install screen comes from
[norns-deps](https://github.com/vehka/norns-deps).

## Uninstall

**SYSTEM > MODS > NB_FLUID > uninstall**, K3 twice. It stops and removes
the service, undoes the rest of the list above, deletes the mod and turns
it off in SYSTEM > MODS. Then restart norns.

Only what the mod installed itself is removed: if fluidsynth was installed
before nb_fluid, it stays. Soundfonts you added to the soundfont folder
stay too.

[modhousekeeper](https://github.com/vehka/modhousekeeper)'s Remove does
the same (it runs the mod's `lib/uninstall.lua` before deleting it).
Deleting the mod any other way (maiden, `rm`) leaves the service and
packages behind; the service then refuses to start, since the mod's files
are gone.

## Soundfonts

Put soundfonts in the mod's own folder:

```
~/dust/data/nb_fluid/soundfonts/
```

The folder is created when the mod loads. The install links the system's
default GM soundfont into it as `default-GM.sf2`. On norns that is the
TimGM6mb soundfont that came with fluidsynth: only ~6 MB, and it sounds
thin.

Better-sounding GM choices:

- **FluidR3_GM.sf2**: FluidSynth's usual default (~140 MB). On Debian it is
  in the `fluid-soundfont-gm` package.
- **GeneralUser GS**: much smaller (~30 MB), a good fit for norns.

Samples load on demand (`synth.dynamic-sample-loading`), so memory use
follows the programs you actually select.

## Choosing a soundfont

The soundfont can be changed while a script plays, to audition soundfonts:
in **PARAMS > fluid synth > soundfont** (shown while a script uses a
`fluid` voice), or in the mod menu. The new soundfont is loaded into the
running FluidSynth, every voice switches to the same program in it, and
the old one is unloaded. Notes keep playing on the old soundfont until the
new one has loaded, which takes a moment for big soundfonts.

The choice is global, like the mod menu's, and not saved in psets.

## Mod menu

**SYSTEM > MODS > NB_FLUID**, E2 selects, E3 changes:

- **soundfont**: which file to load, applied immediately
- **voices**: number of `fluid N` voices, 1-16 (applies on the next script
  load)
- **gain**: FluidSynth master gain, applied immediately (also in PARAMS)
- **setup**: `ok`, or how many dependencies are missing; K3 opens the
  install screen
- **uninstall**: K3, then K3 again to confirm

## MIDI device

In **SYSTEM > DEVICES > MIDI**, assign `fluidsynth` to a port. norns
remembers the assignment like it would for a hardware synth. Then point a
script's MIDI output at that port. Handled messages:

- note on/off
- program change (with CC 0 bank select; CC 32 is ignored)
- all CCs (volume, pan, expression, sustain, reverb/chorus sends,
  all-notes-off, …)
- pitch bend
- GM / GS / XG reset SysEx

Aftertouch is ignored.

MIDI channel N and nb voice `fluid N` are the same FluidSynth channel. An nb
voice only takes over its channel while a script is using it. So for a
multi-channel song, send it through the MIDI device rather than an nb voice.

## Voice params

Once a script selects a `fluid N` voice, its param group shows up:

| param      | what it does                                          |
|------------|-------------------------------------------------------|
| kind       | melodic, or drums (bank 128)                          |
| program    | GM program (melodic)                                  |
| bank       | bank select for non-GM variations (melodic)           |
| kit        | drum kit: Standard, Room, Power, Electronic, TR-808, Jazz, Brush, Orchestra, SFX |
| volume     | CC 7                                                  |
| pan        | CC 10                                                 |
| reverb     | CC 91: FluidSynth's own reverb send                   |
| chorus     | CC 93: FluidSynth's own chorus send                   |
| bend range | pitch bend range in semitones                         |

nb features:

- **pitch bend** is supported; it bends the whole channel
- **modulate** sends the mod wheel (CC 1), which is vibrato in most GM fonts

The program and kit lists assume a GM soundfont: program N is preset N-1
in bank 0, and the kits are the GS drum kits in bank 128. With a non-GM
soundfont the names don't match what plays, so choose presets by bank and
program number instead. A number with no preset behind it doesn't go
silent: an nb voice keeps playing its previous preset, and a MIDI program
change falls back to bank 0 (the same program, or else the first preset).
Either way the log says so. The exception is MIDI channel 10, the drum
channel: it only plays bank 128, so it is silent with a soundfont that has
no drum kits. Kits other than Standard also need a soundfont that has them.
FluidR3_GM and GeneralUser GS both do.

## How it works

FluidSynth runs as the system service `nb-fluid.service`. The mod starts
it (`sudo systemctl restart nb-fluid`) the first time a `fluid` voice is
selected or the MIDI device gets a message, with the soundfont and gain
from `~/dust/data/nb_fluid/service.env`, which the mod writes first. It
drives FluidSynth through its command shell (`noteon`, `select`, `cc`,
...), written to a named pipe, `/tmp/nb_fluid.fifo`. A service rather than a
child process of norns, because the norns 3 beta can't write to a child
process (`io.popen` in write mode).

FluidSynth's JACK outputs are connected to crone's engine inputs (the same
inputs SuperCollider uses). That means the **ENGINE** level, the norns
reverb, and tape recording all apply, as for any engine. FluidSynth keeps
running across script changes, and stops when norns goes to sleep.

FluidSynth's output goes to `/tmp/nb_fluid.log`. Look there if nothing
plays, and at `systemctl status nb-fluid` if it doesn't start.

## License

MIT
