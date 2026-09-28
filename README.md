# NotchPlayer

A macOS notch widget for Spotify. When collapsed, the album art sits to the left of the
notch and animated equalizer bars sit to the right. Hover over the notch and it
expands downward to show artwork, title, artist, progress and prev / play-pause /
next controls. On Macs without a notch it floats as a pill below the menu bar.

Requires macOS 14+, Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build & run

```sh
brew install xcodegen      # once

make gen                   # xcodegen generate → NotchPlayer.xcodeproj (not committed)
make build                 # Debug build into ./build
make run                   # build, quit any running copy, open the .app
make clean                 # delete ./build and the generated project
```

Without make:

```sh
xcodegen generate
xcodebuild -project NotchPlayer.xcodeproj -scheme NotchPlayer -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/NotchPlayer.app
```

The app has no Dock icon or menu. To quit, run `pkill -x NotchPlayer`.

### Signing

By default the app is signed ad-hoc ("Sign to Run Locally") with Hardened Runtime,
so it builds without an Apple developer account. An ad-hoc signature changes on every
rebuild, so macOS may ask for Automation permission again after a rebuild. To keep a
stable identity, sign with your team:

```sh
make build TEAM=XXXXXXXXXX
```

## Automation permission

NotchPlayer reads the artwork and playback position and sends the play/pause/next/previous
commands to Spotify through Apple events. The first time it talks to Spotify, macOS
asks: *"NotchPlayer" wants access to control "Spotify"*. Click **Allow**.

- To change it later, go to **System Settings → Privacy & Security → Automation →
  NotchPlayer → Spotify**. If access is denied, the expanded view shows a hint with
  an **Open Settings** button. Track name, artist and play state still update in
  this case, because Spotify also broadcasts them as a notification. Artwork, live
  position and the controls stop working.
- To reset it, so the prompt appears again:

  ```sh
  tccutil reset AppleEvents com.bilguun.NotchPlayer
  ```

## Debugging

Track changes and AppleScript errors are logged with `os.Logger`:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.bilguun.NotchPlayer"' --level debug
```

(Use `/usr/bin/log` in zsh, because a plain `log` runs a shell builtin.)

## Layout

```
project.yml                        XcodeGen spec (source of truth for the Xcode project)
Sources/
  App/NotchPlayerApp.swift         entry point, AppDelegate, .accessory activation policy
  Window/NotchPanel.swift          borderless non-activating NSPanel + hover/click-through controller
  Window/NotchGeometry.swift       notch detection and shape/panel frames per state
  Spotify/SpotifyController.swift  observable state, notifications, polling, artwork cache
  Spotify/SpotifyScript.swift      NSAppleScript wrappers on a background queue
  Views/                           SwiftUI: root, collapsed, expanded, equalizer
  Resources/                       Info.plist, entitlements
```
