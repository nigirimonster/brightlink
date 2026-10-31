# Brightlink

A small macOS menu-bar app that keeps external monitors' brightness and contrast in step with the MacBook's built-in display, including the keyboard brightness keys. It talks to monitors over DDC/CI using [m1ddc](https://github.com/waydabber/m1ddc).

## Features

- Follows the MacBook brightness and adjusts contrast with it
- Per-monitor settings: sync on/off, offset, brightness range, volume
- Input switching and volume from the menu
- Handles display sleep, wake and lid close
- Launch at login

## Requirements

- Apple Silicon Mac, macOS 13+
- `brew install m1ddc`
- DDC/CI enabled in the monitor's on-screen menu, and not in a preset that locks brightness

## Build

```sh
./build.sh
open Brightlink.app
```

Change `APP_NAME` in `build.sh` to rename the app. Settings are stored in `~/Library/Application Support/<name>/config.json`.

## Notes

- Uses the private `DisplayServices` framework to read the built-in brightness, so it can break with macOS updates.
- Some monitors revert an input switch if the chosen input has no signal (Auto Select).
