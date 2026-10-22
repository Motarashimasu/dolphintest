# Builds the Godot export template with your .pck encryption key compiled in (Windows, x86_64).
# Godot encrypts the exported .pck (scripts, scenes, pictures, music) with this key; only an
# .exe built from this template can read it, so the usual .pck extraction tools find nothing.
# Docs: Frontend/Godot/README.md > "Protecting the .pck".
#
#   powershell -ExecutionPolicy Bypass -File Tools\build_encrypted_template.ps1
#
# Needs: Git, Python 3 (with pip), Visual Studio with "Desktop development with C++" (the same
# MSVC that builds Dolphin). Takes 20-60 minutes the first time.
#
# The key: made the first time in C:\SparkingKeys\godot_pck_key.txt (64 hex characters). Keep it
# with release_private.pem: secret, backed up, never in the repo. The Godot editor needs the same
# key (Export > Encryption); a new key means a new template and a new launcher .exe.
param(
    [string]$KeyFile = "C:\SparkingKeys\godot_pck_key.txt",
    [string]$Source = "C:\SparkingKeys\godot-src",
    # Must be the exact Godot version of your editor (Help > About, e.g. 4.7.2.stable).
    [string]$Tag = "4.7.2-stable"
)
# (Not "Stop": Windows PowerShell 5.1 then aborts when a program like git or python writes to its
# error output while it's redirected. Every step checks its own result instead.)
$ErrorActionPreference = "Continue"

function Need($cmd, $hint) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "$cmd wasn't found. $hint" }
}
Need git "Install Git for Windows (git-scm.com)."
Need python "Install Python 3 from python.org (tick 'Add python.exe to PATH')."

# 1. The key (made once).
if (-not (Test-Path $KeyFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $KeyFile) -ErrorAction Stop | Out-Null
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    (-join ($bytes | ForEach-Object { $_.ToString("x2") })) | Set-Content -NoNewline -Encoding ASCII $KeyFile -ErrorAction Stop
    Write-Host "Made a new key: $KeyFile (back it up, keep it secret)"
}
$key = (Get-Content -Raw $KeyFile).Trim()
if ($key -notmatch '^[0-9a-fA-F]{64}$') { throw "$KeyFile must hold 64 hex characters (a 256-bit key)." }

# 2. SCons, Godot's build tool.
python -m SCons --version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing SCons..."
    python -m pip install --user scons
    if ($LASTEXITCODE -ne 0) { throw "pip couldn't install SCons." }
}

# 3. Godot's source, at your editor's exact version.
if (-not (Test-Path (Join-Path $Source ".git"))) {
    Write-Host "Downloading Godot ${Tag} source..."
    git clone --depth 1 --branch $Tag https://github.com/godotengine/godot.git $Source
    if ($LASTEXITCODE -ne 0) { throw "git couldn't download Godot ${Tag} (is the tag right?)." }
} else {
    $have = (git -C $Source describe --tags --exact-match 2>$null)
    if ($have -ne $Tag) { throw "${Source} holds Godot '${have}', not ${Tag}. Delete that folder (or pass -Source) and run again." }
}

# 4. Build the release template with the key compiled in.
Write-Host "Building the export template (this takes a while)..."
$env:SCRIPT_AES256_ENCRYPTION_KEY = $key
Push-Location $Source
try {
    # d3d12 / accesskit off: the launcher renders with Compatibility (OpenGL) and doesn't use the
    # screen-reader driver; both would need extra SDKs downloaded first.
    python -m SCons platform=windows target=template_release arch=x86_64 production=yes d3d12=no accesskit=no
    if ($LASTEXITCODE -ne 0) { throw "The build failed (see the messages above)." }
} finally {
    Pop-Location
    Remove-Item Env:\SCRIPT_AES256_ENCRYPTION_KEY
}

$exe = Join-Path $Source "bin\godot.windows.template_release.x86_64.exe"
if (-not (Test-Path $exe)) { throw "The build finished but $exe isn't there." }
Write-Host ""
Write-Host "Done: $exe"
Write-Host "Next, in the Godot editor: Project > Export > Windows Desktop:"
Write-Host "  Options > Custom Template > Release: $exe"
Write-Host "  Encryption: tick 'Encrypt Exported PCK' and 'Encrypt Index', Filters to include: *"
Write-Host "  Encryption Key: the 64 characters in $KeyFile"
