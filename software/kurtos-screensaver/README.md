# kurtos-screensaver

A fullscreen screensaver for Linux. It shows the eight bars of the ralleur mark on true black and plays short physical acts: arrival, burst, rain, shuffle, wave, migrate and snake. It is a C port of the ralleur macOS screensaver (Swift), with an SDL3 frontend for Wayland and X11.

Not part of the ISO build yet. The repository has no mechanism for shipping its own software ([docs/development.md](../../docs/development.md)), so this directory only holds the source.

## Build and run

```bash
make                                   # needs sdl3 (Arch/CachyOS: pacman -S sdl3, macOS: brew install sdl3)
./kurtos-screensaver --windowed        # try it in a window
./kurtos-screensaver --windowed --acts snake,burst --seed 7
./kurtos-screensaver                   # fullscreen
```

- **Ending it:** any key, click, scroll, deliberate mouse movement or gamepad button ends it.
- **Idle timer:** it keeps the compositor's idle timer running, so locking and display power-off still happen while it is on screen.

## Starting it on idle (Hyprland)

The Wayland app id is `org.omarchy.screensaver`, so Omarchy's window rules and idle service pick it up as is. On other Hyprland setups (for example CachyOS's Hyprland edition with noctalia), add a fullscreen rule for that class and start it from `hypridle`, for example `on-timeout = kurtos-screensaver` after 150 s.

The screensaver closes all of its instances (one per monitor) through `pkill -f org.omarchy.screensaver`, but only when it was started with `--class org.omarchy.screensaver`.

## Render tool

`kurtos-saver-render` runs the same engine without SDL. It is used for the boot splash keyframes, wallpapers and previews:

```bash
./kurtos-saver-render frames <outdir> <seconds> <fps> <w> <h> [acts] [seed]   # PPM sequence
./kurtos-saver-render at <out.ppm> <seconds> <w> <h> [acts] [seed]            # one frame
./kurtos-saver-render still <out.ppm> <w> <h>                                  # logo at rest
./kurtos-saver-render trace <seconds> <fps> <w> <h> [acts] [seed]             # bar poses as text
```

## Layout

| File | What |
| --- | --- |
| `src/engine.c`, `src/engine.h` | Physics and choreography, without dependencies |
| `src/main.c` | SDL3 frontend: per-bar alpha-mask textures for antialiased edges, input and focus handling |
| `src/render.c` | Headless render and trace tool |
