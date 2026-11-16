
# ============================================================
# MKV CLEANER
# Remove Russian/Ukrainian audio
# Keep English, English SDH and German subtitles
# Set English SDH as default subtitle
# Recursive processing, no re-encoding
# ============================================================

Add-Type -AssemblyName System.Windows.Forms

# FFmpeg installation
$FFmpeg = "D:\Soft\ffmpeg-n9.0.2-57-gd838f9f9ae-win64-gpl-9.0\bin\ffmpeg.exe"
$FFprobe = "D:\Soft\ffmpeg-n9.0.2-57-gd838f9f9ae-win64-gpl-9.0\bin\ffprobe.exe"

# Validate executables
if (!(Test-Path $FFmpeg) -or !(Test-Path $FFprobe)) {
    Write-Host "FFmpeg or FFprobe not found!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# Select input folder
$Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$Dialog.Description = "Select folder containing MKV files"
$Dialog.ShowNewFolderButton = $false

if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "No folder selected."
    exit
}

$InputFolder = $Dialog.SelectedPath

Write-Host "`nSelected folder: $InputFolder" -ForegroundColor Cyan

# Disposition flags supported by FFmpeg
$DispositionNames = @(
    "dub", "original", "comment", "lyrics",
    "karaoke", "forced", "hearing_impaired",
    "visual_impaired", "clean_effects",
    "captions", "descriptions", "metadata",
    "dependent", "still_image", "multilayer"
)

# ------------------------------------------------------------
# Language detection
# ------------------------------------------------------------

function Get-TrackLanguage {
    param($Stream)

    $Tags = $Stream.tags
    $TagProperties = @()

    if ($Tags) {
        $TagProperties = @($Tags.PSObject.Properties)
    }

    $LanguageTags = @(
        $TagProperties |
        Where-Object { $_.Name -match '^language(_ietf)?$' } |
        ForEach-Object { [string]$_.Value }
    )

    $LanguageCodes = $LanguageTags | ForEach-Object {
        $_.Trim().ToLowerInvariant()
    }

    $MetadataText = (
        $TagProperties |
        ForEach-Object { [string]$_.Value }
    ) -join " "

    $MetadataText = $MetadataText.ToLowerInvariant()

    # Russian
    if (
        ($LanguageCodes | Where-Object {
            $_ -match '^(ru|rus)([-_].*)?$'
        }) -or
        $MetadataText -match '\b(russian|rus)\b|русск'
    ) {
        return "Russian"
    }

    # Ukrainian
    if (
        ($LanguageCodes | Where-Object {
            $_ -match '^(uk|ukr)([-_].*)?$'
        }) -or
        $MetadataText -match '\b(ukrainian|ukr)\b|україн|украин'
    ) {
        return "Ukrainian"
    }

    # English
    if (
        ($LanguageCodes | Where-Object {
            $_ -match '^(en|eng)([-_].*)?$'
        }) -or
        $MetadataText -match '\b(english|eng)\b'
    ) {
        return "English"
    }

    # German
    if (
        ($LanguageCodes | Where-Object {
            $_ -match '^(de|deu|ger)([-_].*)?$'
        }) -or
        $MetadataText -match '\b(german|deutsch|deu|ger)\b'
    ) {
        return "German"
    }

    return "Unknown"
}

# ------------------------------------------------------------
# SDH detection
# ------------------------------------------------------------

function Test-SDH {
    param($Stream)

    $Tags = $Stream.tags

    if (!$Tags) {
        return $false
    }

    $Text = (
        $Tags.PSObject.Properties |
        ForEach-Object { [string]$_.Value }
    ) -join " "

    return (
        $Text -match '(?i)\bSDH\b' -or
        $Text -match '(?i)hearing[\s._-]*impaired' -or
        $Text -match '(?i)closed[\s._-]*captions' -or
        $Text -match '(?i)subtitles?\s+for\s+the\s+deaf' -or
        $Text -match '(?i)\[(CC|SDH)\]|\((CC|SDH)\)'
    )
}

# ------------------------------------------------------------
# Find MKV files
# ------------------------------------------------------------

$Files = @(
    Get-ChildItem -LiteralPath $InputFolder `
        -Filter "*.mkv" -File -Recurse |
    Where-Object { $_.BaseName -notmatch '-clean$' }
)

if ($Files.Count -eq 0) {
    Write-Host "No MKV files found." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "`nFound $($Files.Count) MKV files." -ForegroundColor Cyan

# Statistics
$Processed = 0
$Skipped = 0
$Errors = 0

# ------------------------------------------------------------
# Process files
# ------------------------------------------------------------

foreach ($File in $Files) {

    Write-Host "`n================================================" -ForegroundColor DarkGray
    Write-Host "Processing: $($File.Name)" -ForegroundColor Cyan

    $OutputPath = Join-Path $File.DirectoryName `
        ($File.BaseName + "-clean.mkv")

    # Never overwrite existing output
    if (Test-Path -LiteralPath $OutputPath) {
        Write-Host "Output already exists. Skipping." -ForegroundColor Yellow
        $Skipped++
        continue
    }

    # Probe MKV
    $ProbeJson = & $FFprobe -v error `
        -show_entries "stream=index,codec_type:stream_tags:stream_disposition" `
        -of json "$($File.FullName)"

    if ($LASTEXITCODE -ne 0 -or !$ProbeJson) {
        Write-Host "FFprobe failed!" -ForegroundColor Red
        $Errors++
        continue
    }

    try {
        $Probe = $ProbeJson | ConvertFrom-Json
    }
    catch {
        Write-Host "Could not parse FFprobe output!" -ForegroundColor Red
        $Errors++
        continue
    }

    $RemoveIndexes = @()
    $KeptSubtitles = @()

    # Examine every stream
    foreach ($Stream in $Probe.streams) {

        $Language = Get-TrackLanguage $Stream
        $Index = [int]$Stream.index

        if ($Stream.codec_type -eq "audio") {

            if ($Language -in @("Russian", "Ukrainian")) {

                Write-Host "REMOVE AUDIO [$Index]: $Language" -ForegroundColor Red
                $RemoveIndexes += $Index
            }
            else {
                Write-Host "KEEP AUDIO [$Index]: $Language" -ForegroundColor Green
            }
        }

        elseif ($Stream.codec_type -eq "subtitle") {

            if ($Language -in @("English", "German")) {

                $IsSDH = $false

                if ($Language -eq "English") {
                    $IsSDH = Test-SDH $Stream
                }

                $KeptSubtitles += @(
                    [PSCustomObject]@{
                        Index    = $Index
                        Language = $Language
                        SDH      = $IsSDH
                        Stream   = $Stream
                    }
                )

                $Label = $Language

                if ($IsSDH) {
                    $Label += " SDH"
                }

                Write-Host "KEEP SUBTITLE [$Index]: $Label" -ForegroundColor Green
            }
            else {

                Write-Host "REMOVE SUBTITLE [$Index]: $Language" -ForegroundColor Red
                $RemoveIndexes += $Index
            }
        }
    }

    # Find first English SDH subtitle
    $DefaultSDH = $KeptSubtitles |
        Where-Object { $_.Language -eq "English" -and $_.SDH } |
        Select-Object -First 1

    if ($DefaultSDH) {
        Write-Host "Default subtitle: English SDH [$($DefaultSDH.Index)]" -ForegroundColor Cyan
    }
    else {
        Write-Host "WARNING: No English SDH track found." -ForegroundColor Yellow
        Write-Host "No subtitle will be assigned default status." -ForegroundColor Yellow
    }

    # --------------------------------------------------------
    # Construct FFmpeg command
    # --------------------------------------------------------

    $Arguments = @(
        "-hide_banner",
        "-y",
        "-i", $File.FullName,
        "-map", "0",
        "-map_metadata", "0",
        "-map_chapters", "0"
    )

    # Remove unwanted streams
    foreach ($Index in $RemoveIndexes) {
        $Arguments += @("-map", "-0:$Index")
    }

    # Reassign subtitle dispositions
    $SubtitleOrdinal = 0

    foreach ($Subtitle in $KeptSubtitles) {

        $Flags = @()

        # Preserve all existing flags except default
        foreach ($Flag in $DispositionNames) {

            $Value = $Subtitle.Stream.disposition.$Flag

            if ($Value -eq 1) {
                $Flags += $Flag
            }
        }

        # Assign default to English SDH only
        if ($DefaultSDH -and
            $Subtitle.Index -eq $DefaultSDH.Index) {

            $Flags += "default"
        }

        if ($Flags.Count -eq 0) {
            $Disposition = "0"
        }
        else {
            $Disposition = $Flags -join "+"
        }

        $Arguments += @(
            "-disposition:s:$SubtitleOrdinal",
            $Disposition
        )

        $SubtitleOrdinal++
    }

    # Stream copy: no encoding or quality loss
    $Arguments += @(
        "-c", "copy",
        $OutputPath
    )

    # Execute
    & $FFmpeg @Arguments

    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutputPath)) {

        Write-Host "SUCCESS: $OutputPath" -ForegroundColor Green
        $Processed++
    }
    else {

        Write-Host "FAILED: $($File.Name)" -ForegroundColor Red

        Remove-Item -LiteralPath $OutputPath `
            -ErrorAction SilentlyContinue

        $Errors++
    }
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

Write-Host "`n"
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "                 SUMMARY" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

Write-Host "Successfully processed: $Processed" -ForegroundColor Green
Write-Host "Skipped:                $Skipped" -ForegroundColor Yellow
Write-Host "Errors:                 $Errors" -ForegroundColor Red
Write-Host "Total files:            $($Files.Count)"

Write-Host "`nFinished!" -ForegroundColor Cyan

Read-Host "Press Enter to exit"
