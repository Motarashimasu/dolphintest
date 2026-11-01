# Builds the Linux release in one go (Docs/LINUX.md): the newest Linux Dolphin from GitHub, the
# Linux launcher exported from Godot, the game data copied from the Windows build, the player
# .tar.gz, and (with -Publish) the automatic update.
#
#   powershell -ExecutionPolicy Bypass -File Tools\linux_release.ps1 -Version 218
#   powershell -ExecutionPolicy Bypass -File Tools\linux_release.ps1 -Version 218 -Publish
#
# Without -Publish it only shows what the update would upload (a dry run): try the .tar.gz in
# WSL first, then run it again with -Publish.
#
# Your paths: set them once below (or pass -WindowsBuild ... etc.).
# Needs (once): the GitHub CLI (winget install GitHub.cli, then: gh auth login), Python, the
# Godot editor with the "Linux" export preset (Docs/LINUX.md), C:\SparkingKeys as for Windows.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$Publish,
    [string]$WindowsBuild = "E:\DRAGONBALL Sparking! Collection\DRAGONBALL Sparking! Collection",
    [string]$LinuxBuild = "E:\SparkDol\DBZSC-linux",
    [string]$Godot = "C:\Godot\Godot_v4.7.2-stable_win64.exe",
    [string]$Keys = "C:\SparkingKeys",
    [string]$Repo = "Motarashimasu/dolphintest",
    [string]$Branch = "sparking/phase1-frontend-bridge"
)
$ErrorActionPreference = "Continue"
$src = Split-Path -Parent $PSScriptRoot          # the repository (this script is in Tools\)
function Fail($msg) { Write-Host "STOPPED: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail "GitHub CLI not found: winget install GitHub.cli, then gh auth login" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Fail "Python not found." }
if (-not (Test-Path $Godot)) { Fail "Godot editor not found at $Godot (pass -Godot <path to the editor .exe>)." }
if (-not (Test-Path $WindowsBuild)) { Fail "Windows build not found at $WindowsBuild (pass -WindowsBuild)." }
if (-not (Test-Path "$Keys\release.json")) { Fail "$Keys\release.json not found." }
New-Item -ItemType Directory -Force -Path $LinuxBuild | Out-Null

# 1. Dolphin: the newest successful "Linux build" of the branch.
Step "Linux Dolphin from GitHub"
$run = gh run list -R $Repo -w "Linux build" -b $Branch -s success -L 1 --json databaseId,headSha,createdAt | ConvertFrom-Json
if (-not $run) { Fail "No successful Linux build of $Branch on GitHub yet." }
$sha = $run[0].headSha.Substring(0, 8)
Write-Host "Run $($run[0].databaseId), commit $sha, built $($run[0].createdAt)"
$local = (git -C $src rev-parse --short=8 HEAD 2>$null)
if ($local -and $local -ne $sha) {
    Write-Host "Note: your repository is at $local, the Linux Dolphin at $sha. Windows and Linux players can only play together on the same Dolphin: build Windows from $sha too (git pull)." -ForegroundColor Yellow
}
$tmp = Join-Path $env:TEMP "sparking-linux-dolphin"
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
gh run download $run[0].databaseId -R $Repo -n dolphin-sparking-linux-x86_64 -D $tmp
if ($LASTEXITCODE -ne 0) { Fail "Couldn't download the build (gh auth login?)." }
tar -xzf (Join-Path $tmp "dolphin-sparking-linux-x86_64.tar.gz") -C $tmp
if (-not (Test-Path "$tmp\Dolphin\dolphin-emu-nogui")) { Fail "The download has no Dolphin\dolphin-emu-nogui." }
Remove-Item -Recurse -Force "$LinuxBuild\Dolphin" -ErrorAction SilentlyContinue
Move-Item "$tmp\Dolphin" "$LinuxBuild\Dolphin"
Write-Host "Dolphin updated."

# 2. The launcher: Godot's "Linux" export preset, without opening the editor.
Step "Linux launcher (Godot export)"
$exe = Join-Path $LinuxBuild "DRAGON BALL Sparking! Collection.x86_64"
$keyFile = "$Keys\godot_pck_key.txt"
if (Test-Path $keyFile) { $env:GODOT_SCRIPT_ENCRYPTION_KEY = (Get-Content -Raw $keyFile).Trim() }
& $Godot --headless --path (Join-Path $src "Frontend\Godot") --export-release "Linux" $exe 2>&1 | Out-Host
Remove-Item Env:\GODOT_SCRIPT_ENCRYPTION_KEY -ErrorAction SilentlyContinue
if (-not (Test-Path $exe) -or ((Get-Item $exe).LastWriteTime -lt (Get-Date).AddMinutes(-10))) {
    Fail "The export didn't produce a new $exe (is the preset named exactly 'Linux'?)."
}
Write-Host "Launcher exported."

# 3. The game data, from the Windows build (states, textures, netplay saves, disc recipes).
Step "Game data from the Windows build"
foreach ($d in @("SparkingData\states", "SparkingData\textures", "SparkingData\saves\netplay", "SparkingData\discs")) {
    if (Test-Path "$WindowsBuild\$d") {
        robocopy "$WindowsBuild\$d" "$LinuxBuild\$d" /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "Copying $d failed." }
        Write-Host "  $d"
    }
}

# 4. The player download, and the update (dry run unless -Publish).
Step "Package"
$tgz = "$LinuxBuild-$Version.tar.gz"
python "$src\Tools\package_linux.py" $LinuxBuild $tgz --config "$Keys\release.json"
if ($LASTEXITCODE -ne 0) { Fail "Packaging failed." }

Step $(if ($Publish) { "Publish (automatic update)" } else { "Publish: dry run (nothing uploaded)" })
$pubArgs = @("$src\Tools\sparking_release.py", "publish", $LinuxBuild, "--config", "$Keys\release.json", "--version", $Version, "--platform", "linux")
if (-not $Publish) { $pubArgs += "--dry-run" }
python @pubArgs
if ($LASTEXITCODE -ne 0) { Fail "Publishing failed." }

Write-Host ""
Write-Host "Done. Player download: $tgz" -ForegroundColor Green
if (-not $Publish) {
    Write-Host "Try it in WSL (Ubuntu):"
    $wsl = "/mnt/" + $tgz.Substring(0, 1).ToLower() + $tgz.Substring(2).Replace("\", "/")
    Write-Host "  cd ~ && tar -xzf `"$wsl`" && cd `"DRAGON BALL Sparking! Collection`" && ./`"DRAGON BALL Sparking! Collection.x86_64`""
    Write-Host "Then run this again with -Publish."
}
