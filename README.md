# Setlist

A native macOS app that turns a tracklist, a handful of links, or a whole DJ mix into a folder of numbered MP3s.

- **Text**: paste a tracklist. Timestamps, numbering and headers are stripped; each line is searched on YouTube, then SoundCloud.
- **Link**: paste YouTube, SoundCloud or Spotify links. Playlists and albums are expanded. Spotify links are resolved to "Artist - Title" and matched on YouTube, because Spotify serves no audio.
- **YouTube Set**: paste the link of a mix. If a tracklist is posted in the description or comments, it is used. Otherwise the mix is downloaded and identified with Shazam, 30 seconds at a time; each song appears and starts downloading as soon as it is found.

Every download is analysed on your Mac for tempo and key (shown as BPM and a Camelot code such as `8A`, and written to the file's tags). Double-click a finished song to preview it.

## Status

Early and usable, with no packaged release yet: you build it yourself. Known gaps:

- Shazam usually names the original song even when the mix plays a remix. Matching the actual remix is not built yet.
- BPM and key come from a simple on-device analysis. Expect occasional half- or double-tempo readings and relative-key mix-ups.
- An interrupted mix identification resumes from where it stopped; other interrupted downloads are retried from the start of the track.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```sh
git clone https://github.com/jeriel-rb/open-setlist.git
cd open-setlist
bash scripts/fetch-tools.sh     # yt-dlp, ffmpeg and fpcalc into bin/ (about 160 MB)
xcodegen generate
xcodebuild -project Setlist.xcodeproj -scheme Setlist -configuration Debug \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build
open build/Build/Products/Debug/Setlist.app
```

Or run `xcodegen generate`, open `Setlist.xcodeproj` and press Run.

`scripts/fetch-tools.sh` is optional if you already have `yt-dlp` and `ffmpeg` from Homebrew; the app looks in `/opt/homebrew/bin` and `/usr/local/bin` when its own `bin/` is empty.

Built this way, with ad-hoc signing, everything works except Shazam identification. Mixes with a posted tracklist still work.

## Shazam identification

ShazamKit only answers apps signed by an Apple Developer team that has enabled the service, so this part needs a paid Apple Developer account.

1. At [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list), register an App ID with an explicit bundle ID of your own, and tick **ShazamKit** under **App Services**.
2. Put that bundle ID in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`).
3. Copy `Local.xcconfig.example` to `Local.xcconfig` and set `DEVELOPMENT_TEAM` to your 10-character team ID. This file is git-ignored.
4. Build without the ad-hoc override:

   ```sh
   xcodegen generate
   xcodebuild -project Setlist.xcodeproj -scheme Setlist -configuration Debug \
     -derivedDataPath build -allowProvisioningUpdates build
   ```

The app checks Shazam before downloading a mix, so a build that is not set up for it says so within a few seconds.

## Where things go

- Downloads: `~/Documents/Setlist/<job name>/`, as `01 - Artist - Title.mp3`, with `tracklist.txt`, `failed.txt` and a `job.json` that holds the job's state. Change the folder in Settings.
- A newer yt-dlp fetched from Settings → Update: `~/Library/Application Support/Setlist/bin/`.

## What leaves your Mac

- Requests to YouTube, SoundCloud and Spotify for the things you paste, made by yt-dlp and the app.
- Audio signatures sent to Apple's Shazam service when a mix is identified by listening. The audio itself is not uploaded.
- A download of yt-dlp from GitHub when you press Update.

There is no account, no analytics and no server of ours. Tempo and key analysis runs locally.

## Development

All logic lives in the Swift package `Packages/SetlistCore` and is covered by unit tests; the app target in `Setlist/` is a thin SwiftUI layer.

```sh
cd Packages/SetlistCore
swift test                    # unit tests, no network
SETLIST_LIVE=1 swift test     # also runs tests that download and call Shazam
```

Debug builds accept `-demoShazam YES` as a launch argument, which names songs from a fixed list instead of asking Shazam. It lets you try the YouTube Set flow in a build that is not signed for ShazamKit.

The app icon is drawn by `swift scripts/make-icon.swift`.

## Legal

Setlist is a front end for [yt-dlp](https://github.com/yt-dlp/yt-dlp). Downloading may be against the terms of the service you download from, and the music is copyrighted by its owners. Use it only for content you have the right to download, and follow the law where you live. The authors take no responsibility for how it is used.

The repository contains none of the third-party tools. `scripts/fetch-tools.sh` downloads them from their own projects, each under its own license: yt-dlp (Unlicense), FFmpeg (GPL/LGPL, depending on the build) and Chromaprint's fpcalc (LGPL/MIT). If you redistribute a built app that bundles them, their licenses apply to you.

Shazam and ShazamKit are Apple's. This project is not affiliated with Apple, YouTube, SoundCloud or Spotify.

## License

MIT. See [LICENSE](LICENSE).
