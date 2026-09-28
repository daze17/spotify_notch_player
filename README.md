# NotchPlayer

A macOS notch widget for Spotify, in the style of the iPhone's Dynamic Island. When
collapsed it stays within the menu bar: artwork and the song title on the left of the
notch, the artist and animated equalizer bars on the right. Hover and it expands
downward to show artwork, title, artist, a seekable progress bar, prev / play-pause /
next controls and the **Up next** queue. Move the pointer away, or click anywhere
else, to close it. On Macs
without a notch it floats as a pill below the menu bar.

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

## Up next (queue)

Spotify's AppleScript interface can't see the queue, so NotchPlayer reads it from the
Spotify Web API. This needs a free Spotify developer app, set up once:

1. Go to <https://developer.spotify.com/dashboard> and click **Create app**.
   - Name and description can be anything.
   - **Redirect URI**: `http://127.0.0.1:43117/callback` (exactly this, then click **Add**).
   - Under **Which API/SDKs are you planning to use?**, tick **Web API**.
2. Open the app's **Settings** and copy the **Client ID**.
3. Create `Config/Local.xcconfig` (git-ignored) containing:

   ```
   SPOTIFY_CLIENT_ID = paste_your_client_id_here
   ```

4. `make run`, hover over the notch, and click **Connect**. Your browser opens Spotify's
   login page. Approve it and the tab says you can close it.

Notes:

- Login uses OAuth with PKCE, so there's no client secret. The tokens are stored in
  the macOS Keychain. With ad-hoc signing, the Keychain may ask whether NotchPlayer
  can access the item after a rebuild. Click **Always Allow**, or build with
  `TEAM=…` (see Signing).
- New Spotify developer apps start in *development mode*, which only allows accounts
  listed under the app's **User Management** page. The owner's account is allowed.
- The list shows everything Spotify returns for the queue. Scroll to see more than four.
- Click a queued song to skip to it. Spotify has no "jump to queue item" command, so
  NotchPlayer presses *next* that many times. With Spotify Free, those count against
  your skip limit.
- Right-click the **UP NEXT** header to disconnect your account.
- The queue refreshes when the track changes, when the player opens, and every 10 s
  while it's open.

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
  Spotify/QueueController.swift    observable "Up next" state + polling
  Spotify/SpotifyWebAPI.swift      Web API client (GET /me/player/queue)
  Spotify/SpotifyAuth.swift        OAuth PKCE login + token refresh
  Spotify/LoopbackRedirectServer.swift  catches the OAuth redirect on 127.0.0.1
  Support/                         Keychain wrapper, shared image cache
  Views/                           SwiftUI: root, collapsed, expanded, queue, marquee, equalizer
  Resources/                       Info.plist, entitlements
Config/Spotify.xcconfig            SPOTIFY_CLIENT_ID (override in Config/Local.xcconfig)
```
