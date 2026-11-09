# Builds APIS-K0: release zip with the game folder layout. With -Install copies the files into the game.
# Everything under src\ is already laid out like the game folder (r6\scripts, r6\tweaks, bin\x64\...).
# The bridge is the RED4ext plugin (launcher\build.bat, launcher\build_deps.bat): no Apiko.exe and no Python since
# 0.2.0. -Install removes the Apiko.exe a 0.1.0 install left in the mod folder's bridge\ subfolder.
# The CET mod's dev.lua (development hotkeys, debug log, Senses window) is never in the zip. -Install also copies it
# (a development install); -Install -Release installs exactly what the zip has and removes it from the game.
# -Game: the Cyberpunk 2077 folder (for -Install). -WolvenKit: WolvenKit.CLI.exe (default: the workspace's copy in
# ..\_shared, else WolvenKit.CLI on the PATH).
param([switch]$Install, [switch]$Release, [string]$Version = '0.2.0',
      [string]$Game = 'C:\Steam\steamapps\common\Cyberpunk 2077', [string]$WolvenKit = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src'
$game = $Game
$modRel = 'bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0'
$bridgeSrc = Join-Path $root 'bridge'

# ApisK0.archive: the wreck in the world and the find in the journal. tools\make_world.py writes the WolvenKit JSON,
# the CLI turns it into CR2W and packs the folder (the archive takes the folder's name).
$wk = $WolvenKit
if (-not $wk) {
    $wk = Join-Path (Split-Path $root -Parent) '_shared\WolvenKit Console\WolvenKit.CLI.exe'
    if (-not (Test-Path $wk)) { $wk = 'WolvenKit.CLI.exe' }
}
$archiveDir = Join-Path $root 'build\archive'
$archiveSrc = Join-Path $archiveDir 'ApisK0'
Remove-Item $archiveDir -Recurse -Force -ErrorAction SilentlyContinue
& (Join-Path $bridgeSrc '.venv\Scripts\python.exe') (Join-Path $PSScriptRoot 'make_world.py') $archiveSrc
if ($LASTEXITCODE) { throw "make_world.py failed ($LASTEXITCODE)" }
$log = & $wk convert deserialize $archiveSrc 2>&1 | ForEach-Object { "$_" }
if ($log -match 'Error') { $log; throw 'WolvenKit deserialize failed' }
Get-ChildItem $archiveSrc -Recurse -Filter *.json | Where-Object { Test-Path ($_.FullName -replace '\.json$', '') } |
    Remove-Item
$log = & $wk pack $archiveSrc -o $archiveDir 2>&1 | ForEach-Object { "$_" }
$archive = Join-Path $archiveDir 'ApisK0.archive'
if (-not (Test-Path $archive)) { $log; throw 'WolvenKit pack failed' }

# (source file, path in the game folder)
$devRel = "$modRel\dev.lua"
$devSrc = Join-Path $src $devRel
$files = @(Get-ChildItem $src -Recurse -File | Where-Object { $_.FullName -ne $devSrc } |
    ForEach-Object { , @($_.FullName, $_.FullName.Substring($src.Length + 1)) })
$files += , @($archive, 'archive\pc\mod\ApisK0.archive')
# Data the bridge reads from the mod's data\ folder.
$files += @('prompt.md', 'config.example.json', 'barks.json', 'lore.json', 'first_contact.json', 'beacon_es.wav', 'beacon_en.wav' |
    ForEach-Object { , @((Join-Path $bridgeSrc $_), "$modRel\data\$_") })
# The bridge: a RED4ext plugin that runs inside the game (launcher\build.bat).
$launcher = Join-Path $root 'launcher\out\ApisK0Launcher.dll'
if (-not (Test-Path $launcher)) { throw "Missing ${launcher}: run launcher\build.bat" }
$files += , @($launcher, 'red4ext\plugins\ApisK0\ApisK0Launcher.dll')
# Piper in the native bridge: onnxruntime next to the plugin, espeak-ng's data (only the Spanish and English
# dictionaries) with the mod's data (launcher\build_deps.bat).
$files += , @((Join-Path $root 'launcher\out\onnxruntime.dll'), 'red4ext\plugins\ApisK0\onnxruntime.dll')
$espeakData = Join-Path $root 'launcher\deps\build\espeak-ng\espeak-ng-data'
if (-not (Test-Path (Join-Path $espeakData 'phontab'))) { throw "Missing ${espeakData}: run launcher\build_deps.bat" }
$files += @(Get-ChildItem $espeakData -Recurse -File |
    Where-Object { $_.Name -notlike '*_dict' -or $_.Name -in 'es_dict', 'en_dict' } |
    ForEach-Object { , @($_.FullName, (Join-Path "$modRel\data\espeak-ng-data" $_.FullName.Substring($espeakData.Length + 1))) })

$zip = Join-Path $root "dist\ApisK0-$Version.zip"
New-Item -ItemType Directory -Force (Split-Path $zip) | Out-Null
Remove-Item $zip -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::Open($zip, 'Create')
foreach ($f in $files) {
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $f[1].Replace('\', '/'), 'Optimal') | Out-Null
}
$z.Dispose()
Write-Host ("Zip: $zip ({0:N0} MB)" -f ((Get-Item $zip).Length / 1MB))

if ($Install) {
    # 0.1.0's Python bridge (Apiko.exe and its _internal folder, about 350 MB) and its development switch.
    $oldBridge = Join-Path $game "$modRel\bridge"
    foreach ($old in 'Apiko.exe', '_internal', 'native.on') {
        $p = Join-Path $oldBridge $old
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Host "Removed old $p" }
    }
    foreach ($f in $files) {
        $dst = Join-Path $game $f[1]
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item $f[0] $dst -Force
    }
    if ($Release) {
        Remove-Item (Join-Path $game $devRel) -ErrorAction SilentlyContinue
        Write-Host "Installed into $game (release: no dev tools)"
    } else {
        Copy-Item $devSrc (Join-Path $game $devRel) -Force
        Write-Host "Installed into $game (development: dev.lua)"
    }
}
