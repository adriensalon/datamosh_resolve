# Datamosh for DaVinci Resolve

**Datamosh Cut** applies an incoming shot's Xvid motion to pixels from the outgoing shot. **Datamosh Bloom** repeats an Xvid P-frame so motion accumulates within a clip. Both keep a baked image sequence for scrubbing and export.

## Install on Windows

Run the installer from this folder. It installs the bundled Windows x64 FFmpeg and FFprobe with their licenses. [See the dependency inventory](external/ffmpeg/COMPONENTS.md).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\InstallDatamosh.ps1
```

To use your own FFmpeg build, pass `-FFmpegPath` with the path to `ffmpeg.exe`. The build must support libxvid and have `ffprobe.exe` beside it. Restart Resolve after installation and use **Bake Datamosh** in the Inspector. The installer keeps the bake script under `%LOCALAPPDATA%\ResolveDatamosh`, outside Resolve's Scripts menu.

On upgrade, the installer backs up renamed files and old menu scripts in the same folder. Existing cached frames are preserved. Inspector buttons from earlier Inspector-only installs can still rebake. Effects created before the Inspector-only install need a fresh instance to rebake.

## Datamosh Cut

1. Drop **Datamosh Cut** from **Video Transitions** onto an edit with available clip handles.
2. Select the transition on the **Edit** page and click **Bake Datamosh** in the Inspector.
3. Scrub the transition. The image lands on the clean incoming shot.

**Anchor Offset** chooses an outgoing frame relative to the start of the transition. **Motion Offset** shifts which incoming frames supply the motion. If a positive offset shortens the donor range, its last available P-frame repeats during the tail.

## Datamosh Bloom

1. Drop **Datamosh Bloom** from **Effects** onto a clip.
2. In the **Edit** page, place the playhead where the bloom should start, set **Bloom Duration**, and click **Bake Datamosh** in the effect's Inspector.
3. Scrub the clip. The original image plays before and after the bake.

**Motion Offset** selects the starting frame of the pair used to encode the repeated P-frame.

## Preview and cache

**Codec Size** sets the maximum long edge used for the Xvid pass. Smaller values give coarser blocks and faster bakes. **Xvid Quantizer** changes the compression of motion and pixel corrections. Click **Bake Datamosh** again after changing settings, input clips, or timing.

The cache is an 8-bit SDR RGB PNG sequence with opaque alpha. Keep the sequence under `%LOCALAPPDATA%\ResolveDatamosh\Jobs` with the project when moving it to a different workstation.
