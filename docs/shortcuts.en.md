# Complete key list

[Back to README](../README.en.md)

Every **keyboard** key can be changed in `script-opts/quick_cut.conf` (`key_*` / `crop_key_*`); separate multiple keys with commas, leave the field blank to disable. The left mouse button and the wheel are force-bound by the script while the editor is open and are not configurable. Inside a panel, press `?` for a key reference for the current context.

> The tables list primary keys only. Some actions also carry an alias or a keypad equivalent (e.g. `?` / `K`, `ENTER` / `KP_ENTER`, `←` / `KP4`); `script-opts/quick_cut.conf` is the source of truth for the full defaults.

## Main editor

| Key | Action | Key | Action |
| :--- | :--- | :--- | :--- |
| `SPACE` | play / pause | `[` / `]` | set in / out point |
| `ENTER` | add segment / save edit | `s` | split at playhead |
| `DEL` | delete selected segment | `x` | clear (segments + marks + crop) |
| `z` / `y` | undo / redo (also inside crop editing) | `l` | segment list |
| `↑` / `↓` | previous / next segment | `t` | enter a segment timecode |
| `g` | seek to a timecode | `Ctrl+SPACE` | clear the current selection |
| `←` / `→` | back / forward 1 second (works while playing, no pause) | `Alt+←/→` | previous / next keyframe |
| `Ctrl+←/→` | frame step (pauses playback; when marks exist: nudges the mark and jumps to it) | `r` | add / remove playback range |
| `e` | export | `m` | merge export |
| `c` | crop (opens the crop window) | `w` | waveform toggle |
| `f` | save current frame | `h` | collapse / expand the button panel |
| `?` | key reference | `q` / `ESC` | close the editor |

## Crop window

| Key | Action | Key | Action |
| :--- | :--- | :--- | :--- |
| `← ↑ ↓ →` | move the crop rectangle | `Shift+arrows` | move faster |
| `-` / `+` | shrink / grow | `Ctrl+-` / `Ctrl+=` | shrink / grow faster |
| `c` | centre | `h` | show / hide HUD |
| `z` / `y` | undo / redo | `SPACE` | play / pause |
| `?` | key reference | `ENTER` | done |
| `q` / `ESC` | cancel | | |

**Crop window toolbar**:

- Fixed at the bottom centre of the picture, kept inside the picture area on narrow windows;
- Hides automatically when it intersects the crop rectangle (including when fully inside it), so the picture stays clear;
- `h` collapses or summons it manually; manual collapse and automatic hiding are independent, so a collapsed toolbar will not reappear on intersection;
- The main panel and timeline are hidden while crop editing is active and come back with `h` too;
- The size label sits centred between the window top and the crop rectangle's top edge, so it never collides with the rectangle or its handles.

## Export confirmation panel

| Key | Action |
| :--- | :--- |
| `ENTER` | activate the focused item (start export / confirm an option) |
| `TAB` / `SHIFT+TAB` | next / previous focus |
| `↑` / `↓` | adjust the focused parameter (moves the dropdown highlight when open) |
| `BS` (Backspace) | restore the focused parameter to its original-parameter value |
| `?` | key reference |
| `q` / `ESC` | close the overlay first, then the panel |
