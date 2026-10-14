#!/bin/sh
# Run by nb-fluid.service (see setup.lua). Settings come from service.env;
# shell commands come from the FIFO the mod writes to.

[ -p "$FIFO" ] || { rm -f "$FIFO" && mkfifo -m 600 "$FIFO"; } || exit 1
echo $$ > "$PIDFILE"

# Opened read-write, so the open doesn't wait for the mod, and fluidsynth
# never reads end-of-file when the mod closes its end or restarts.
exec 3<>"$FIFO"
exec fluidsynth -a jack -n -r "$SAMPLE_RATE" \
  -o audio.jack.id="$JACK_ID" -o audio.jack.autoconnect=0 \
  -o synth.polyphony="$POLYPHONY" -o synth.dynamic-sample-loading=1 \
  -g "$GAIN" "$SOUNDFONT" <&3 3<&- >"$LOG" 2>&1
