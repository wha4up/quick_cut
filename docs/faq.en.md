# FAQ

[Back to README](../README.en.md)

UI icons, export speed, audio compatibility, progress memory, undo scope, why speed / rotation / filters set in the player never reach the exported file, what still works without ffmpeg, and which speed values export accepts — the questions that come up most.

---

### The UI icons are gone, buttons show text only?

**libass did not load the bundled icon font.** libass scans exactly **one** font directory: whatever `osd-fonts-dir` points to in `mpv.conf`, or mpv's default `~~/fonts`. Dropping `quick_cut/` into `scripts/` is therefore not enough on its own. The script checks that directory at startup:

- if it holds neither the icon font nor any other font, the script temporarily points `osd-fonts-dir` at the bundled `scripts/quick_cut/fonts/` (for this run only, your `mpv.conf` is not modified) and icons render correctly;
- if it already holds other fonts, the script does not take over: it hides all icons, shows text labels only (never empty boxes), and leaves a note in the mpv log.

For stable icons, do one of two things: copy `scripts/quick_cut/fonts/Quickcut_icons.ttf` into `portable_config/fonts/` (or `~~/fonts/`), or set `osd-fonts-dir=~~/scripts/quick_cut/fonts` in `mpv.conf`. That option takes **one** directory only — joining several with `;`, `:` or `|` does not work.

---

### Export got slower?

**Usually because re-encoding kicked in.** Fast copy (stream copy) normally completes in a second or two when you only change the in/out points and add no filters; adjusting encoding parameters, enabling crop / filters, or a target container that cannot hold the source codecs all switch to re-encoding automatically.

---

### The player can't read the audio track after export?

**Check whether the target container supports the source audio codec.** When it does not, the script switches to a codec the container does support and tells you, instead of producing a file that muxes fine but plays no audio.

---

### Where is the editing progress stored, and how do I clear it?

**In `quick_cut_sessions.json` next to the script** (`~~/scripts/quick_cut/quick_cut_sessions.json`, same lifecycle as the script). All media share this **one** JSON store, keyed by media path, capped at the 20 most recent entries.

The `resume_session` option controls it; set it to `no` to stop recording. To drop one entry, press `x` (clear) in the studio — that also deletes the session for the current media. To clear everything, delete the JSON file.

---

### What can undo / redo cover?

**Segment editing and cropping share one history.** Setting marks, adding, splitting, deleting, reordering, clearing, timeline dragging, segment handle nudging, plus crop ratio, move, scale, align, drag and cancel are all undoable. **One drag counts as one step**, and `z` / `y` work while crop editing. Export type, encoding preset and the automatic-pass toggles are export settings, not editing results, so they stay out of the history.

---

### Why don't the player's speed, rotation or filters appear in the exported file?

**That is by design.** Quick Cut always regenerates the output from the source media streams; playback-only speed, reverse playback, rotation, flipping and any `vf` / `af` filters affect the player only. Rotation metadata stored in the source file belongs to the container and is kept by stream copy. To bake such effects into the output, post-process the export with another tool.

> Note the distinction: the "speed" in the export settings is an **export setting** and does take effect in the output (see the next entry); the speed mentioned here means temporary playback speed.

---

### Can I use it without ffmpeg?

**Yes.** When ffmpeg is missing the script falls back to mpv's built-in encoders, so every re-encode export (video, audio extraction, image sequences, animated images) keeps working; for what you lose, see the [capability table in the README](../README.en.md#export-capabilities-without-ffmpeg).

The features you lose are greyed out in the panel — clicking or toggling them does nothing, and hovering states the reason. The panel opens on a usable choice (for example "Re-encode" rather than "Fast copy"), and pressing `m` for merge export reports the reason instead of opening the panel. Installing ffmpeg makes the script prefer it automatically — no configuration needed; restart mpv for it to take effect.

---

### What speed values does export support?

**0.25x to 4x, with the audio keeping its pitch.** Set "Speed" in the export parameters; it requires re-encoding (fast copy cannot do it, the UI switches automatically with a hint). Values outside 0.25–4 are clamped to the range. This feature needs ffmpeg and is refused with a hint when it is missing.
