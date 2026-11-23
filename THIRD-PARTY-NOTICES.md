# Third-party software in the Setlist download

Setlist's own code is under the MIT licence (see `LICENSE`). The packaged app also contains three
separate command-line programs, which Setlist runs as they are and does not modify or link against.
Each stays under its own licence.

| Program | What Setlist uses it for | Licence | Source |
|---|---|---|---|
| yt-dlp | Reading pages and downloading audio | The Unlicense (its standalone build also bundles Python and libraries under their own licences) | https://github.com/yt-dlp/yt-dlp |
| FFmpeg | Converting audio to MP3, writing tags | GNU General Public License, version 3 or later (this build is configured with `--enable-gpl`) | https://ffmpeg.org/download.html, build from https://github.com/eugeneware/ffmpeg-static |
| fpcalc (Chromaprint) | Audio fingerprints | GNU Lesser General Public License 2.1 or later; MIT for its own source | https://github.com/acoustid/chromaprint |

The exact versions are whatever `scripts/fetch-tools.sh` downloaded when the package was built; each
program prints its version with `--version` or `-version`. The licence texts are at
https://www.gnu.org/licenses/gpl-3.0.html, https://www.gnu.org/licenses/lgpl-2.1.html and
https://unlicense.org.

ShazamKit is part of macOS and is not included in the download.
