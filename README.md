# nb_fluid

An [nb](https://llllllll.co/t/n-b-et-al-v0-1/60374) voice mod for norns that
plays [FluidSynth](https://www.fluidsynth.org/): General MIDI sounds on norns
from any SoundFont (`.sf2` / `.sf3`).

Two ways in, both driving one shared FluidSynth instance:

- **nb voices** `fluid 1` … `fluid N`: each is one MIDI channel. Pick any of
  the 128 GM programs, or switch a voice to drums and choose a drum kit.
- **a virtual MIDI device** called `fluidsynth`: a 16-channel General MIDI
  synth for any script with MIDI out, e.g. a MIDI file player. The song
  picks its own instruments with program changes, and drums are on
  channel 10.

## Requirements

- norns with the [nb](https://github.com/sixolet/nb) library (used by the
  script, not installed separately)
- `fluidsynth` built with JACK support. On norns:

  ```
  sudo apt install fluidsynth
  ```

- a General MIDI soundfont (see below)

## Install

```
;install https://github.com/vehka/nb_fluid
```

Then enable it in **SYSTEM > MODS**, and restart norns.

## Soundfonts

Put soundfonts in the mod's own folder:

```
~/dust/data/nb_fluid/soundfonts/
```

The folder is created when the mod loads. Choose the active soundfont in the
mod menu. Good GM choices:

- **FluidR3_GM.sf2**: FluidSynth's usual default (~140 MB). On Debian it is
  in the `fluid-soundfont-gm` package, installed to
  `/usr/share/sounds/sf2/`; symlink or copy it into the folder above.
- **GeneralUser GS**: much smaller (~30 MB), a good fit for norns.

Samples load on demand (`synth.dynamic-sample-loading`), so memory use
follows the programs you actually select.

## Mod menu

**SYSTEM > MODS > NB_FLUID**, E2 selects, E3 changes:

- **soundfont**: which file to load. FluidSynth restarts with the new font
  when you leave the menu.
- **voices**: number of `fluid N` voices, 1-16 (applies on the next script
  load)
- **gain**: FluidSynth master gain, applied immediately

## MIDI device

In **SYSTEM > DEVICES > MIDI**, assign `fluidsynth` to a port. norns
remembers the assignment like it would for a hardware synth. Then point a
script's MIDI output at that port. Handled messages:

- note on/off
- program change (with CC 0/32 bank select)
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

Kits other than Standard need a soundfont that has them. FluidR3_GM and
GeneralUser GS both do.

## How it works

The mod starts `fluidsynth` the first time a `fluid` voice is selected or
the MIDI device gets a message, and
drives it through its command shell over a pipe (`noteon`, `select`, `cc`,
...). FluidSynth's JACK outputs are connected to crone's engine inputs (the
same inputs SuperCollider uses). That means the **ENGINE** level, the norns
reverb, and tape recording all apply, as for any engine. FluidSynth keeps
running across script changes, and quits when norns does.

FluidSynth's output goes to `/tmp/nb_fluid.log`. Look there if nothing plays.

## License

MIT
