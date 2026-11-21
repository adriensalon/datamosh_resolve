# Datamosh runtime dependencies

The installer copies this bundle to `%LOCALAPPDATA%\ResolveDatamosh\ffmpeg`. Datamosh launches FFmpeg and FFprobe as separate command-line processes.

| Component | Used for | License |
| --- | --- | --- |
| `bin/ffmpeg.exe` | Reads the OpenEXR captures as `image2` sequences, resizes and pads frames, writes raw MPEG-4 Part 2 (`m4v`), then decodes the edited stream to a PNG sequence. The filters are `scale`, `pad`, `setsar`, and `setpts`. | [GPL-3.0-or-later for this build](LICENSE) |
| `bin/ffprobe.exe` | Reads the width and height of the anchor capture. | [GPL-3.0-or-later for this build](LICENSE) |
| Xvid (`libxvidcore`, built into FFmpeg) | Encodes the anchor and donor passes as MPEG-4 Part 2 through `libxvid`. | [GPL, upstream license text](licenses/Xvid.txt) |
| zlib (built into FFmpeg) | Compresses the baked PNG frames and handles ZIP-compressed OpenEXR captures. | [zlib license](licenses/zlib.txt) |
| Datamosh Studio | No runtime component. The project’s `InvokeDatamosh.ps1` edits MPEG-4 picture data. | — |

## Build provenance

`4.3.2-2021-02-27-full_build-www.gyan.dev` is the Windows x64 static build used by Datamosh on this machine. The executables, license, and [original build notes](README.txt) are unchanged copies from that package. The build notes identify the [FFmpeg source revision `fbb9368226`](https://github.com/FFmpeg/FFmpeg/commit/fbb9368226). The Xvid license is from the [upstream Xvid source package](https://labs.xvid.com/source/), and the zlib notice is from the [upstream zlib README](https://github.com/madler/zlib/blob/v1.2.11/README).

The build configuration lists the other statically linked libraries. It gives the FFmpeg source revision and leaves the exact revisions of those libraries unspecified. For redistribution, [GPLv3 section 6](https://www.gnu.org/licenses/gpl-3.0.html#section6) covers the complete corresponding source for the binaries.
