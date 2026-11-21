param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[a-zA-Z0-9-]+\z')]
    [string] $JobId,

    [string] $JobRoot = (Join-Path $env:LOCALAPPDATA 'ResolveDatamosh\Jobs')
)

$ErrorActionPreference = 'Stop'
$job = Join-Path $JobRoot $JobId
$statusPath = Join-Path $job 'status.txt'

function Invoke-FFmpeg {
    param([string[]] $Arguments)

    & $ffmpeg @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg exited with code $LASTEXITCODE. See ffmpeg.log in the job folder."
    }
}

function Get-Pictures([byte[]] $Bytes) {
    $search = 3
    while ($search -lt ($Bytes.Length - 1)) {
        $marker = [Array]::IndexOf($Bytes, [byte]0xB6, $search)
        if ($marker -lt 0 -or $marker + 1 -ge $Bytes.Length) { break }
        if ($Bytes[$marker - 3] -eq 0 -and $Bytes[$marker - 2] -eq 0 -and $Bytes[$marker - 1] -eq 1) {
            [pscustomobject]@{
                Offset = $marker - 3
                Type = 'IPBS'[$Bytes[$marker + 1] -shr 6]
            }
        }
        $search = $marker + 1
    }
}

function Get-CaptureFrames([string] $Directory) {
    Get-ChildItem -LiteralPath $Directory -File -Filter '*.exr' |
        ForEach-Object {
            if ($_.Name -notmatch '\A([a-zA-Z_.]+)(-?\d+)\.exr\z') {
                throw "Unexpected capture filename: $($_.Name)"
            }
            [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Frame = [int]$Matches[2]; Prefix = $Matches[1]; Digits = $Matches[2].Length }
        } | Sort-Object Frame
}

function Write-Picture($Stream, [byte[]] $Bytes, $Pictures, [int] $Index) {
    $offset = $Pictures[$Index].Offset
    $end = if ($Index + 1 -lt $Pictures.Count) { $Pictures[$Index + 1].Offset } else { $Bytes.Length }
    $Stream.Write($Bytes, $offset, $end - $offset)
}

try {
    $config = ConvertFrom-StringData -StringData (Get-Content -Raw -LiteralPath (Join-Path $job 'job.txt'))
    $count = [int]$config.Count
    $quantizer = [int]$config.Quantizer
    $maxWidth = [int]$config.Width
    $rate = [double]::Parse($config.Rate, [Globalization.CultureInfo]::InvariantCulture)
    if ($rate -le 0 -or $rate -gt 120 -or $count -lt 2 -or $count -gt 120 -or
        $quantizer -lt 2 -or $quantizer -gt 20 -or $maxWidth -lt 320 -or $maxWidth -gt 1920 -or
        $config.Mode -notin @('Transition', 'Bloom')) {
        throw 'Invalid datamosh settings.'
    }

    $ffmpeg = $env:RESOLVE_DATAMOSH_FFMPEG
    $ffmpegConfig = Join-Path $PSScriptRoot 'ffmpeg-path.txt'
    if (-not $ffmpeg -and (Test-Path -LiteralPath $ffmpegConfig -PathType Leaf)) {
        $ffmpeg = (Get-Content -Raw -LiteralPath $ffmpegConfig).Trim()
    }
    if (-not $ffmpeg) { $ffmpeg = (Get-Command ffmpeg.exe -ErrorAction Stop).Source }
    $ffprobe = Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
        throw 'ffprobe.exe must be beside ffmpeg.exe.'
    }

    $anchorFolder = Join-Path $job 'anchor'
    $motionFolder = Join-Path $job 'motion'
    $anchor = @(Get-ChildItem -LiteralPath $anchorFolder -File -Filter '*.exr')
    $motion = @(Get-CaptureFrames $motionFolder)
    $requiredMotion = [int]$config.DonorCount
    if ($requiredMotion -lt 2 -or $requiredMotion -gt $count -or
        ($config.Mode -eq 'Bloom' -and $requiredMotion -ne 2)) {
        throw 'Invalid donor frame count.'
    }
    if ($anchor.Count -ne 1 -or $motion.Count -ne $requiredMotion) {
        throw "Incomplete Fusion capture. Expected 1 anchor and $requiredMotion donor frames, got $($anchor.Count) and $($motion.Count)."
    }
    for ($i = 1; $i -lt $motion.Count; $i++) {
        if ($motion[$i].Frame -ne $motion[0].Frame + $i) { throw 'The donor image sequence has a gap.' }
    }

    $geometry = & $ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $anchor[0].FullName
    if ($LASTEXITCODE -ne 0 -or $geometry -notmatch '\A(\d+),(\d+)\z') {
        throw 'Could not read the dimensions of the anchor image.'
    }
    $sourceWidth = [int]$Matches[1]
    $sourceHeight = [int]$Matches[2]
    $ratio = [Math]::Min(1.0, $maxWidth / [double][Math]::Max($sourceWidth, $sourceHeight))
    $width = [Math]::Max(2, 2 * [Math]::Floor($sourceWidth * $ratio / 2))
    $height = [Math]::Max(2, 2 * [Math]::Floor($sourceHeight * $ratio / 2))
    $filter = "scale=$($width):$($height):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=$($width):$($height):(ow-iw)/2:(oh-ih)/2,setsar=1"

    $motionPattern = Join-Path $motionFolder ($motion[0].Prefix + '%0' + $motion[0].Digits + 'd.exr')
    $anchorVideo = Join-Path $job 'anchor.m4v'
    $motionVideo = Join-Path $job 'motion.m4v'
    $moshedVideo = Join-Path $job 'moshed.m4v'
    $log = Join-Path $job 'ffmpeg.log'
    $encode = @('-an', '-vf', $filter, '-vsync', '0', '-pix_fmt', 'yuv420p',
        '-c:v', 'libxvid', '-bf', '0', '-g', '250', '-q:v', "$quantizer", '-f', 'm4v')
    $common = @('-nostdin', '-hide_banner', '-loglevel', 'warning', '-y')

    # Redirect FFmpeg diagnostics without turning its normal stderr warnings into PowerShell errors.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Invoke-FFmpeg ($common + @('-f', 'image2', '-framerate', $config.Rate, '-i', $anchor[0].FullName, '-frames:v', '1') + $encode + @($anchorVideo)) 2>> $log
        Invoke-FFmpeg ($common + @('-f', 'image2', '-framerate', $config.Rate,
            '-start_number', "$($motion[0].Frame)", '-i', $motionPattern) + $encode + @($motionVideo)) 2>> $log

        $anchorBytes = [IO.File]::ReadAllBytes($anchorVideo)
        $lastAnchorStart = $anchorBytes.Length - 4
        if ($lastAnchorStart -ge 0 -and
            $anchorBytes[$lastAnchorStart] -eq 0 -and $anchorBytes[$lastAnchorStart + 1] -eq 0 -and
            $anchorBytes[$lastAnchorStart + 2] -eq 1 -and $anchorBytes[$lastAnchorStart + 3] -eq 0xB1) {
            $anchorLength = $lastAnchorStart
        } else {
            $anchorLength = $anchorBytes.Length
        }
        $donor = [IO.File]::ReadAllBytes($motionVideo)
        $pictures = @(Get-Pictures $donor)
        if ($pictures.Count -ne $requiredMotion -or $pictures[0].Type -ne 'I' -or
            @($pictures | Where-Object { $_.Type -notin @('I', 'P') }).Count -gt 0) {
            throw 'Xvid produced an unexpected picture sequence.'
        }

        $firstP = 1
        while ($firstP -lt $pictures.Count -and $pictures[$firstP].Type -ne 'P') { $firstP++ }
        if ($firstP -eq $pictures.Count) {
            throw 'The donor contains no P-frames. Try an offset with continuous motion.'
        }

        $stream = [IO.File]::Create($moshedVideo)
        try {
            $stream.Write($anchorBytes, 0, $anchorLength)
            $usable = $firstP
            for ($i = 1; $i -lt $count; $i++) {
                if ($config.Mode -eq 'Transition' -and $i -lt $pictures.Count -and $pictures[$i].Type -eq 'P') {
                    $usable = $i
                }
                Write-Picture $stream $donor $pictures $usable
            }
        } finally {
            $stream.Dispose()
        }

        $frameFolder = Join-Path $job 'frames'
        New-Item -ItemType Directory -Path $frameFolder -Force | Out-Null
        Invoke-FFmpeg ($common + @('-f', 'm4v', '-threads', '1', '-i', $moshedVideo,
            '-vf', "setpts=N/($($config.Rate)*TB)", '-vsync', '0', '-c:v', 'png', '-pix_fmt', 'rgb24',
            '-start_number', '0', (Join-Path $frameFolder 'mosh%06d.png'))) 2>> $log
    } finally {
        $ErrorActionPreference = $savedPreference
    }

    $baked = @(Get-ChildItem -LiteralPath $frameFolder -File -Filter 'mosh*.png')
    if ($baked.Count -ne $count -or -not (Test-Path -LiteralPath (Join-Path $frameFolder 'mosh000000.png'))) {
        throw "The mosh decoded to $($baked.Count) frames. Expected $count."
    }

    Remove-Item -LiteralPath $anchor[0].FullName
    foreach ($capture in $motion) { Remove-Item -LiteralPath $capture.Path }
    foreach ($intermediate in @($anchorVideo, $motionVideo, $moshedVideo)) {
        Remove-Item -LiteralPath $intermediate
    }
    [IO.File]::WriteAllText($statusPath, "OK $count")
} catch {
    [IO.File]::WriteAllText($statusPath, "ERROR $($_.Exception.Message)")
    Write-Error $_
    exit 1
}

