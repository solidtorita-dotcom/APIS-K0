# Builds APIS-K0: release zip with the game folder layout. With -Install copies the files into the game.
# Everything under src\ is already laid out like the game folder (r6\scripts, r6\tweaks, bin\x64\...).
# The bridge goes in as Apiko.exe (PyInstaller, no Python needed) in the mod folder's bridge\ subfolder.
# -Bridge rebuilds it (a few minutes); without it the last build in build\bridge is reused.
# The CET mod's dev.lua (development hotkeys, debug log, Senses window) is never in the zip. -Install also copies it
# (a development install); -Install -Release installs exactly what the zip has and removes it from the game.
# -Game: the Cyberpunk 2077 folder (for -Install). -WolvenKit: WolvenKit.CLI.exe (default: the workspace's copy in
# ..\_shared, else WolvenKit.CLI on the PATH).
param([switch]$Install, [switch]$Bridge, [switch]$Release, [string]$Version = '0.1.0',
      [string]$Game = 'C:\Steam\steamapps\common\Cyberpunk 2077', [string]$WolvenKit = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src'
$game = $Game
$modRel = 'bin\x64\plugins\cyber_engine_tweaks\mods\ApisK0'
$bridgeSrc = Join-Path $root 'bridge'
$bridgeBuild = Join-Path $root 'build\bridge'
$bridgeOut = Join-Path $bridgeBuild 'dist\Apiko'

if ($Bridge -or -not (Test-Path (Join-Path $bridgeOut 'Apiko.exe'))) {
    $python = Join-Path $bridgeSrc '.venv\Scripts\python.exe'
    $data = 'prompt.md', 'barks.json', 'first_contact.json', 'lore.json', 'config.example.json', 'beacon_es.wav', 'beacon_en.wav' |
        ForEach-Object { '--add-data'; "$(Join-Path $bridgeSrc $_);." }
    # Packages that load data files or DLLs at runtime, which PyInstaller does not find on its own.
    $collect = 'piper', 'kokoro_onnx', 'espeakng_loader', 'faster_whisper', 'phonemizer', 'language_tags' |
        ForEach-Object { '--collect-all'; $_ }
    # PyInstaller logs to stderr, which Windows PowerShell turns into errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    & $python -m PyInstaller --noconfirm --clean --log-level WARN --name Apiko --console `
        --distpath (Join-Path $bridgeBuild 'dist') --workpath (Join-Path $bridgeBuild 'work') --specpath $bridgeBuild `
        @data --hidden-import apiko_voice @collect --collect-data sounddevice --collect-binaries ctranslate2 `
        (Join-Path $bridgeSrc 'apiko_bridge.py') 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE) { throw "PyInstaller failed ($LASTEXITCODE)" }
    Write-Host "Bridge: $bridgeOut"
}

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
# Data the native bridge reads from the mod's data\ folder (the Python bridge has it inside Apiko.exe).
$files += @('prompt.md', 'config.example.json', 'barks.json', 'lore.json', 'first_contact.json', 'beacon_es.wav', 'beacon_en.wav' |
    ForEach-Object { , @((Join-Path $bridgeSrc $_), "$modRel\data\$_") })
$files += @(Get-ChildItem $bridgeOut -Recurse -File |
    ForEach-Object { , @($_.FullName, (Join-Path "$modRel\bridge" $_.FullName.Substring($bridgeOut.Length + 1))) })
# RED4ext plugin that starts the bridge with the game (launcher\build.bat).
$launcher = Join-Path $root 'launcher\out\ApisK0Launcher.dll'
if (-not (Test-Path $launcher)) { throw "Missing ${launcher}: run launcher\build.bat" }
$files += , @($launcher, 'red4ext\plugins\ApisK0\ApisK0Launcher.dll')

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
