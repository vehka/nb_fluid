-- General MIDI level 1 program names (programs 0-127) and the common
-- GS/GM2 drum kit programs found in bank 128 of most GM soundfonts.

local gm = {}

gm.programs = {
  -- piano
  "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano",
  "Honky-tonk Piano", "Electric Piano 1", "Electric Piano 2", "Harpsichord",
  "Clavinet",
  -- chromatic percussion
  "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone",
  "Tubular Bells", "Dulcimer",
  -- organ
  "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
  "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
  -- guitar
  "Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Clean Guitar",
  "Muted Guitar", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
  -- bass
  "Acoustic Bass", "Fingered Bass", "Picked Bass", "Fretless Bass",
  "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
  -- strings
  "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings",
  "Pizzicato Strings", "Orchestral Harp", "Timpani",
  -- ensemble
  "String Ensemble 1", "String Ensemble 2", "Synth Strings 1",
  "Synth Strings 2", "Choir Aahs", "Voice Oohs", "Synth Voice",
  "Orchestra Hit",
  -- brass
  "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn",
  "Brass Section", "Synth Brass 1", "Synth Brass 2",
  -- reed
  "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe",
  "English Horn", "Bassoon", "Clarinet",
  -- pipe
  "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi",
  "Whistle", "Ocarina",
  -- synth lead
  "Square Lead", "Saw Lead", "Calliope Lead", "Chiff Lead", "Charang Lead",
  "Voice Lead", "Fifths Lead", "Bass + Lead",
  -- synth pad
  "New Age Pad", "Warm Pad", "Polysynth Pad", "Choir Pad", "Bowed Pad",
  "Metallic Pad", "Halo Pad", "Sweep Pad",
  -- synth effects
  "FX Rain", "FX Soundtrack", "FX Crystal", "FX Atmosphere", "FX Brightness",
  "FX Goblins", "FX Echoes", "FX Sci-fi",
  -- ethnic
  "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle",
  "Shanai",
  -- percussive
  "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum",
  "Melodic Tom", "Synth Drum", "Reverse Cymbal",
  -- sound effects
  "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet",
  "Telephone Ring", "Helicopter", "Applause", "Gunshot",
}

-- drum kits live in bank 128; `prog` is the program number within it.
gm.drum_kits = {
  { name = "Standard", prog = 0 },
  { name = "Room", prog = 8 },
  { name = "Power", prog = 16 },
  { name = "Electronic", prog = 24 },
  { name = "TR-808", prog = 25 },
  { name = "Jazz", prog = 32 },
  { name = "Brush", prog = 40 },
  { name = "Orchestra", prog = 48 },
  { name = "SFX", prog = 56 },
}

gm.program_options = {}
for i, name in ipairs(gm.programs) do
  gm.program_options[i] = i .. " " .. name
end

gm.drum_kit_options = {}
for i, kit in ipairs(gm.drum_kits) do
  gm.drum_kit_options[i] = kit.name
end

return gm
