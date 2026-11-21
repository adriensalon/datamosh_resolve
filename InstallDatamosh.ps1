param([string] $FFmpegPath)

$ErrorActionPreference = 'Stop'
$bundle = Join-Path $PSScriptRoot 'external\ffmpeg'
$useBundledFFmpeg = -not $FFmpegPath
if ($useBundledFFmpeg) {
    $FFmpegPath = Join-Path $bundle 'bin\ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $FFmpegPath -PathType Leaf)) {
        throw 'The FFmpeg bundle is missing. Use the complete Datamosh folder or pass -FFmpegPath.'
    }
}
$FFmpegPath = (Resolve-Path -LiteralPath $FFmpegPath).Path
$ffprobe = Join-Path (Split-Path -Parent $FFmpegPath) 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
    throw 'Install ffprobe.exe beside ffmpeg.exe.'
}
$encoders = & $FFmpegPath -hide_banner -encoders
if ($LASTEXITCODE -ne 0 -or -not ($encoders -match '\blibxvid\b')) {
    throw 'Datamosh requires an FFmpeg build with the libxvid encoder.'
}

$fusion = Join-Path $env:APPDATA 'Blackmagic Design\DaVinci Resolve\Support\Fusion'
$local = Join-Path $env:LOCALAPPDATA 'ResolveDatamosh'
if ($useBundledFFmpeg) {
    $installedBundle = Join-Path $local 'ffmpeg'
    New-Item -ItemType Directory -Force -Path $installedBundle | Out-Null
    Get-ChildItem -LiteralPath $bundle | Copy-Item -Destination $installedBundle -Recurse -Force
    $FFmpegPath = Join-Path $installedBundle 'bin\ffmpeg.exe'
}

$files = [ordered]@{
    'Datamosh.fuse' = (Join-Path $fusion 'Fuses\Datamosh.fuse')
    'BakeDatamosh.lua' = (Join-Path $local 'BakeDatamosh.lua')
    'InvokeDatamosh.ps1' = (Join-Path $local 'InvokeDatamosh.ps1')
}

foreach ($name in $files.Keys) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing $name." }
    $destination = $files[$name]
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $local 'Jobs') | Out-Null
[IO.File]::WriteAllText((Join-Path $local 'ffmpeg-path.txt'), $FFmpegPath)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$templates = Join-Path $fusion 'Templates'
New-Item -ItemType Directory -Force -Path $templates | Out-Null
$templateBundle = Join-Path $templates 'Datamosh.drfx'
$stagingPath = Join-Path $templates ('Datamosh-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    $archive = [IO.Compression.ZipFile]::Open($stagingPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,
            (Join-Path $PSScriptRoot 'DatamoshCut.setting'), 'Edit/Transitions/Datamosh Cut.setting')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,
            (Join-Path $PSScriptRoot 'DatamoshBloom.setting'), 'Edit/Effects/Datamosh Bloom.setting')
    } finally {
        $archive.Dispose()
    }
    if (Test-Path -LiteralPath $templateBundle) {
        [IO.File]::Replace($stagingPath, $templateBundle, [NullString]::Value)
    } else {
        [IO.File]::Move($stagingPath, $templateBundle)
    }
} finally {
    if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath }
}

$legacyFiles = @(
    Join-Path $fusion 'Scripts\Comp\Bake Datamosh.lua'
    Join-Path $fusion 'Scripts\Comp\Restore Datamosh Playback.lua'
    Join-Path $templates 'Edit\Transitions\Datamosh Cut.setting'
    Join-Path $templates 'Edit\Transitions\DatamoshCut.setting'
    Join-Path $templates 'Edit\Effects\Datamosh Bloom.setting'
    Join-Path $templates 'Edit\Effects\DatamoshBloom.setting'
    Join-Path $local 'Invoke-Datamosh.ps1'
)

# Existing timeline effects store the old private script path in their buttons.
$legacyBake = Join-Path $local 'Bake Datamosh.lua'
$launcher = @'
local bake = assert(loadfile(os.getenv("LOCALAPPDATA") .. "\\ResolveDatamosh\\BakeDatamosh.lua"))
setfenv(bake, getfenv(1))()
'@
if ((Test-Path -LiteralPath $legacyBake -PathType Leaf) -and [IO.File]::ReadAllText($legacyBake) -cne $launcher) {
    $legacyFiles += $legacyBake
}
foreach ($legacyPath in $legacyFiles) {
    if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { continue }
    $name = [IO.Path]::GetFileNameWithoutExtension($legacyPath)
    $extension = [IO.Path]::GetExtension($legacyPath)
    $backupName = '{0}.backup-{1}{2}' -f $name, [guid]::NewGuid().ToString('N'), $extension
    $backupPath = Join-Path $local $backupName
    Move-Item -LiteralPath $legacyPath -Destination $backupPath
    Write-Output "Backed up $legacyPath to $backupPath"
}
[IO.File]::WriteAllText($legacyBake, $launcher)

Write-Output 'Installed Datamosh Cut and Datamosh Bloom. Restart Resolve and use Bake Datamosh in the Inspector.'

