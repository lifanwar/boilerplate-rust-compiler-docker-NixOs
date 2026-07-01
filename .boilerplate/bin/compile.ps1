Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = (Resolve-Path (Join-Path $ScriptDir "../..")).Path
$StateDir = Join-Path $Root ".boilerplate/state"
$ConfigFile = if ($env:BOILERPLATE_CONFIG) { $env:BOILERPLATE_CONFIG } else { Join-Path $Root ".boilerplate.env" }

$script:ComposeFile = ""
$script:ImageName = ""
$script:BinaryExt = ""
$script:TargetMode = "linux"

$SharedRegistry = "boilerplate-compile-cargo-registry"
$SharedGit = "boilerplate-compile-cargo-git"

Set-Location $Root
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Import-BoilerplateEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "[WARN] File config '$Path' tidak ditemukan."
        return
    }

    foreach ($rawLine in Get-Content $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        $value = $value -replace '^["'']|["'']$', ''

        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

Import-BoilerplateEnv $ConfigFile

# ── Mode: pilih compose file + image + target sesuai command ──────────
function Set-TargetMode {
    param([string]$Mode)

    $script:TargetMode = $Mode
    if ($Mode -eq "windows") {
        $script:ComposeFile = Join-Path $Root ".boilerplate/compose-windows.yml"
        $script:ImageName = "boilerplate-compile-rust-windows:stable"
        $script:BinaryExt = ".exe"
    } else {
        $script:ComposeFile = Join-Path $Root ".boilerplate/compose.yml"
        $script:ImageName = "boilerplate-compile-rust:stable"
        $script:BinaryExt = ""
    }
}

# Set default mode (linux) — akan di-override per command
Set-TargetMode "linux"

$VpsSsh = if ($env:VPS_SSH) { $env:VPS_SSH } else { "" }
$VpsSshPort = if ($env:VPS_SSH_PORT) { $env:VPS_SSH_PORT } else { "22" }
$AppPort = if ($env:APP_PORT) { $env:APP_PORT } else { "3000" }
$LocalPort = if ($env:LOCAL_PORT) { $env:LOCAL_PORT } else { $AppPort }
$RustTarget = if ($env:RUST_TARGET -and $env:RUST_TARGET -ne "auto") { $env:RUST_TARGET } else { "x86_64-pc-windows-gnu" }

function Log {
    param([string]$Message)
    $time = Get-Date -Format "HH:mm:ss"
    Write-Host "[$time] $Message"
}

function Fail {
    param([string]$Message)
    Write-Error "Error: $Message"
    exit 1
}

function Need {
    param([string]$Command)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Fail "Perintah '$Command' tidak tersedia. Install dulu atau jalankan dari terminal yang sudah punya PATH benar."
    }
}

function Package-Name {
    $metadata = cargo metadata --no-deps --format-version 1 2>$null | ConvertFrom-Json
    if ($metadata.packages.Count -gt 0) {
        return $metadata.packages[0].name
    }
    return ""
}

function Safe-Name {
    param([string]$Name)
    $safe = $Name.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $safe = $safe.Trim("-")
    if ($safe.Length -gt 32) {
        return $safe.Substring(0, 32)
    }
    return $safe
}

function Ensure-ProjectId {
    $idFile = Join-Path $StateDir "project-id"

    if (-not (Test-Path $idFile) -or ((Get-Item $idFile).Length -eq 0)) {
        Log "Membuat project ID baru..."
        $name = Safe-Name (Package-Name)
        if (-not $name) {
            $name = Safe-Name (Split-Path -Leaf $Root)
        }
        if (-not $name) {
            $name = "rust-project"
        }

        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $rng.Dispose()
        $random = -join ($bytes | ForEach-Object { $_.ToString("x2") })
        "$name-$random" | Set-Content -NoNewline $idFile
    }

    $script:ProjectId = (Get-Content $idFile -Raw).Trim()
    $script:ComposeProjectName = "bc-$script:ProjectId"

    if (-not $env:REMOTE_PORT) {
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($script:ProjectId)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash($hashBytes)
        $number = [BitConverter]::ToUInt32($hash, 0)
        $script:RemotePort = 40000 + ($number % 20000)
    } else {
        $script:RemotePort = [int]$env:REMOTE_PORT
    }

    $env:PROJECT_ID = $script:ProjectId
    $env:COMPOSE_PROJECT_NAME = $script:ComposeProjectName
    $env:APP_PORT = $AppPort
    $env:LOCAL_PORT = $LocalPort
    $env:REMOTE_PORT = "$script:RemotePort"
    $env:RUST_TARGET = $RustTarget

    Log "Project ID: $script:ProjectId"
}

function Select-Compose {
    docker compose version *> $null
    if ($LASTEXITCODE -eq 0) {
        $script:ComposeMode = "docker-compose-plugin"
        return
    }

    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        $script:ComposeMode = "docker-compose-standalone"
        return
    }

    Fail "Docker Compose tidak tersedia."
}

function Invoke-Compose {
    $composeArgs = @(
        "--project-directory", (Join-Path $Root ".boilerplate")
        "-f", $script:ComposeFile
        "-p", $script:ComposeProjectName
    ) + $args

    if ($script:ComposeMode -eq "docker-compose-plugin") {
        & docker compose @composeArgs
    } else {
        & docker-compose @composeArgs
    }
}

function Configure-Remote {
    if (-not $VpsSsh) {
        Fail "Salin .boilerplate.env.example menjadi .boilerplate.env, lalu isi VPS_SSH."
    }

    $env:DOCKER_HOST = "ssh://${VpsSsh}:${VpsSshPort}"
    $env:COMPOSE_DOCKER_CLI_BUILD = "1"
    $env:DOCKER_BUILDKIT = "1"
}

function Preflight {
    Log "Memeriksa prerequisite..."
    Need "cargo"
    Need "docker"
    Need "ssh"
    Need "tar"

    Configure-Remote
    Select-Compose

    Log "Menguji koneksi SSH ke ${VpsSsh}:${VpsSshPort}..."
    ssh -p $VpsSshPort -o BatchMode=yes -o ConnectTimeout=10 $VpsSsh true
    if ($LASTEXITCODE -ne 0) {
        Fail "SSH ke $VpsSsh gagal. Cek koneksi dan SSH key."
    }
    Log "SSH OK"

    Log "Mengakses Docker daemon via SSH..."
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker daemon pada VPS tidak dapat diakses oleh $VpsSsh."
    }
    Log "Docker daemon OK"
}

function Ensure-SharedVolumes {
    docker volume inspect $SharedRegistry *> $null
    if ($LASTEXITCODE -ne 0) {
        docker volume create `
            --label com.boilerplate-compile.managed=true `
            --label com.boilerplate-compile.shared=true `
            $SharedRegistry *> $null
    }

    docker volume inspect $SharedGit *> $null
    if ($LASTEXITCODE -ne 0) {
        docker volume create `
            --label com.boilerplate-compile.managed=true `
            --label com.boilerplate-compile.shared=true `
            $SharedGit *> $null
    }
}

function Get-FileHashText {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
}

function Ensure-BuilderImage {
    $hashFile = Join-Path $StateDir "builder-$($script:TargetMode)-hash"
    $dockerfile = if ($script:TargetMode -eq "windows") {
        Join-Path $Root ".boilerplate/docker/Dockerfile.windows"
    } else {
        Join-Path $Root ".boilerplate/docker/Dockerfile"
    }

    if (-not (Test-Path $dockerfile)) {
        # fallback ke Dockerfile umum
        $dockerfile = Join-Path $Root ".boilerplate/docker/Dockerfile"
    }

    $currentHash = Get-FileHashText $dockerfile
    $previousHash = ""
    if (Test-Path $hashFile) {
        $previousHash = (Get-Content $hashFile -Raw).Trim()
    }

    $imageMissing = $true
    try {
        $null = docker image inspect $script:ImageName 2>$null
        if ($LASTEXITCODE -eq 0) { $imageMissing = $false }
    } catch { }

    if ($imageMissing -or $currentHash -ne $previousHash) {
        Log "Membangun image builder ($($script:TargetMode)) di VPS (Dockerfile berubah/baru)..."
        $env:BUILDKIT_PROGRESS = "plain"
        Invoke-Compose build workspace
        Remove-Item Env:BUILDKIT_PROGRESS -ErrorAction SilentlyContinue
        $currentHash | Set-Content -NoNewline $hashFile
        Log "Image builder selesai dibangun"
    } else {
        Log "Image builder ($($script:TargetMode)) sudah ada dan up-to-date"
    }
}

function Ensure-Workspace {
    Ensure-SharedVolumes
    Ensure-BuilderImage

    $containerId = Invoke-Compose ps -a -q workspace 2>$null
    if ($containerId) {
        Log "Menyalakan container workspace yang sudah ada..."
        Invoke-Compose start workspace
        Log "Container workspace aktif"
    } else {
        Log "Membuat container workspace baru..."
        Invoke-Compose create workspace 2>$null
        Invoke-Compose start workspace
        Log "Container workspace siap"
    }
}

function Ensure-Lockfile {
    if (-not (Test-Path (Join-Path $Root "Cargo.lock"))) {
        Log "Membuat Cargo.lock lokal..."
        cargo generate-lockfile
        Log "Cargo.lock selesai"
    } else {
        Log "Cargo.lock sudah ada"
    }
}

function Sync-Source {
    Ensure-Lockfile
    Ensure-Workspace
    Log "Membuat arsip source..."
    $syncStart = Get-Date
    $tmpTar = Join-Path $env:TEMP "boilerplate-sync-$PID.tar"

    tar `
        --exclude="./.git" `
        --exclude="./target" `
        --exclude="./result" `
        --exclude="./dist" `
        --exclude="./.direnv" `
        --exclude="./.boilerplate.env" `
        --exclude="./.boilerplate/state" `
        -C $Root -cf $tmpTar .

    if ($LASTEXITCODE -ne 0) {
        Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue
        Fail "Gagal membuat arsip source"
    }
    Log "Mengirim arsip ke container VPS..."
    Invoke-Compose cp $tmpTar workspace:/tmp/boilerplate-sync.tar

    Log "Mengekstrak di container..."
    Invoke-Compose exec -T workspace sh -lc "find /workspace -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf -- {} + && tar -xf /tmp/boilerplate-sync.tar -C /workspace && rm /tmp/boilerplate-sync.tar"
    $extractOk = $LASTEXITCODE

    Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue

    if ($extractOk -ne 0) {
        Fail "Sync source gagal dengan kode error $extractOk"
    }

    $elapsed = [math]::Round(((Get-Date) - $syncStart).TotalSeconds, 1)
    Log ("Source berhasil dikirim (" + $elapsed + "s)")
}
function Detect-Bin {
    param([string]$Requested)

    if ($Requested) {
        return $Requested
    }

    $metadata = cargo metadata --no-deps --format-version 1 | ConvertFrom-Json
    $bins = @($metadata.packages[0].targets | Where-Object { $_.kind -contains "bin" })

    if ($bins.Count -eq 0) {
        Fail "Target binary tidak ditemukan."
    }
    if ($bins.Count -ne 1) {
        Fail "Ada lebih dari satu binary. Gunakan --bin NAMA."
    }

    return $bins[0].name
}

$script:Release = $false
$script:BinRequest = ""
$script:CargoArgs = @()
$script:ProgramArgs = @()

function Parse-BuildArgs {
    param([string[]]$Args)

    $script:Release = $false
    $script:BinRequest = ""
    $script:CargoArgs = @()
    $script:ProgramArgs = @()

    $i = 0
    while ($i -lt $Args.Count) {
        if ($Args[$i] -eq "--release") {
            $script:Release = $true
            $i++
        } elseif ($Args[$i] -eq "--bin") {
            if ($i + 1 -ge $Args.Count) {
                Fail "--bin membutuhkan nama binary."
            }
            $script:BinRequest = $Args[$i + 1]
            $i += 2
        } elseif ($Args[$i] -eq "--") {
            if ($i + 1 -lt $Args.Count) {
                $script:ProgramArgs = @($Args[($i + 1)..($Args.Count - 1)])
            }
            break
        } else {
            $script:CargoArgs += $Args[$i]
            $i++
        }
    }
}

function Remote-BuildAndCopy {
    param([string]$BinName)

    $profile = "debug"
    $releaseArgs = @()
    if ($script:Release) {
        $profile = "release"
        $releaseArgs = @("--release")
    }

    Sync-Source

    if ($script:TargetMode -eq "windows") {
        Log "Compile $BinName untuk Windows di VPS..."
        $buildArgs = @("exec", "-T", "workspace", "cargo", "build") +
            $releaseArgs +
            @("--target", $RustTarget, "--bin", $BinName) +
            $script:CargoArgs

        $outputDir = Join-Path $Root "target/remote/windows/$profile"
        $destination = Join-Path $outputDir "$BinName$script:BinaryExt"
        $temporary = "$destination.tmp"
        $containerPath = "/workspace/target/$RustTarget/$profile/$BinName$script:BinaryExt"
    } else {
        Log "Compile $BinName untuk Linux di VPS..."
        $buildArgs = @("exec", "-T", "workspace", "cargo", "build") +
            $releaseArgs +
            @("--bin", $BinName) +
            $script:CargoArgs

        $outputDir = Join-Path $Root "target/remote/linux/$profile"
        $destination = Join-Path $outputDir "$BinName"
        $temporary = "$destination.tmp"
        $containerPath = "/workspace/target/$profile/$BinName"
    }

    $buildStart = Get-Date
    Invoke-Compose @buildArgs
    $elapsed = [math]::Round(((Get-Date) - $buildStart).TotalSeconds, 1)
    Log "Build selesai ($elapseds)"

    Log "Menyalin binary dari container ke $destination..."
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    Remove-Item -Force -ErrorAction SilentlyContinue $temporary

    Invoke-Compose cp "workspace:$containerPath" $temporary
    Move-Item -Force $temporary $destination
    Log "Binary disalin: $destination"

    return $destination
}

function Cmd-Build {
    param([string[]]$Args)
    Log "=== BUILD ==="
    Set-TargetMode "windows"
    Parse-BuildArgs $Args
    $binName = Detect-Bin $script:BinRequest
    $output = Remote-BuildAndCopy $binName
    Log "Hasil build: $output"
}

function Cmd-RunLocal {
    param([string[]]$Args)
    Log "=== RUN-LOCAL ==="
    Set-TargetMode "windows"
    Parse-BuildArgs $Args
    $binName = Detect-Bin $script:BinRequest
    $output = Remote-BuildAndCopy $binName

    Log "Menjalankan lokal: $output"
    $programArgs = $script:ProgramArgs
    & $output @programArgs
    exit $LASTEXITCODE
}

function Cmd-Dev {
    param([string[]]$Args)
    Log "=== DEV ==="
    Set-TargetMode "linux"
    Parse-BuildArgs $Args
    $binName = Detect-Bin $script:BinRequest

    Sync-Source

    Log "Membuat SSH tunnel: localhost:$LocalPort -> container:$AppPort"
    Log "Aplikasi harus listen pada 0.0.0.0:$AppPort di dalam container."

    $sshArgs = @(
        "-p", $VpsSshPort,
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-N",
        "-L", "127.0.0.1:${LocalPort}:127.0.0.1:${script:RemotePort}",
        $VpsSsh
    )
    $tunnel = Start-Process -FilePath "ssh" -ArgumentList $sshArgs -PassThru -WindowStyle Hidden

    try {
        Start-Sleep -Seconds 1
        if ($tunnel.HasExited) {
            Fail "SSH tunnel gagal dibuat."
        }
        Log "SSH tunnel berhasil"

        $releaseArgs = @()
        if ($script:Release) {
            $releaseArgs = @("--release")
        }

        $runArgs = @(
            "exec",
            "-e", "HOST=0.0.0.0",
            "-e", "PORT=$AppPort",
            "-e", "APP_PORT=$AppPort",
            "workspace",
            "cargo",
            "run"
        ) + $releaseArgs +
            @("--bin", $binName) +
            $script:CargoArgs +
            @("--") +
            $script:ProgramArgs
        Log "Menjalankan cargo run di container..."
        Invoke-Compose @runArgs
    } finally {
        if ($tunnel -and -not $tunnel.HasExited) {
            Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Cmd-Check {
    param([string[]]$Args)
    Log "=== CHECK ==="
    Set-TargetMode "linux"
    Sync-Source
    Log "Menjalankan cargo check di container..."
    Invoke-Compose @(@("exec", "-T", "workspace", "cargo", "check") + $Args)
    Log "cargo check selesai (exit code: $LASTEXITCODE)"
}

function Cmd-Test {
    param([string[]]$Args)
    Log "=== TEST ==="
    Set-TargetMode "linux"
    Sync-Source
    Log "Menjalankan cargo test di container..."
    Invoke-Compose @(@("exec", "-T", "workspace", "cargo", "test") + $Args)
    Log "cargo test selesai (exit code: $LASTEXITCODE)"
}

function Cmd-Stop {
    Log "=== STOP ==="
    Set-TargetMode "linux"
    Ensure-Workspace
    Log "Menghentikan proses aplikasi di container..."
    Invoke-Compose exec -T workspace sh -lc 'pkill -INT -f "cargo run" 2>/dev/null || true; pkill -INT -f "/workspace/target/.*/(debug|release)/" 2>/dev/null || true'
    Log "Proses aplikasi remote dihentikan. Cache tetap disimpan."
}

function Cmd-Clean {
    Log "=== CLEAN ==="
    Set-TargetMode "linux"
    Log "Menghapus container dan volume project dari VPS..."
    Invoke-Compose down --volumes --remove-orphans
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $Root "target/remote")
    Log "Container, network, source mirror, dan target cache project telah dihapus dari VPS."
    Log "Image builder dan cache Cargo bersama tetap disimpan."
}

function Cmd-Purge {
    Log "=== PURGE ==="
    Set-TargetMode "linux"
    Cmd-Clean

    Log "Menghapus seluruh container bertanda boilerplate-compile..."
    $containers = docker ps -aq --filter label=com.boilerplate-compile.managed=true
    if ($containers) {
        docker rm -f @containers *> $null
    }

    Log "Menghapus seluruh network bertanda boilerplate-compile..."
    $networks = docker network ls -q --filter label=com.boilerplate-compile.managed=true
    if ($networks) {
        docker network rm @networks *> $null
    }

    Log "Menghapus seluruh volume bertanda boilerplate-compile..."
    $volumes = docker volume ls -q --filter label=com.boilerplate-compile.managed=true
    if ($volumes) {
        docker volume rm -f @volumes *> $null
    }

    Log "Menghapus image builder..."
    docker image rm -f $script:ImageName *> $null
    Log "Seluruh resource boilerplate-compile pada VPS telah dihapus."
}

function Cmd-Status {
    Log "=== STATUS ==="
    Set-TargetMode "linux"
    Write-Host "  Project ID : $script:ProjectId"
    Write-Host "  VPS        : $VpsSsh"
    Write-Host "  Docker URI : $env:DOCKER_HOST"
    Write-Host "  Target     : $RustTarget"
    Write-Host "  Port       : localhost:$LocalPort -> VPS 127.0.0.1:$script:RemotePort -> container:$AppPort"
    Log "Docker Compose:"
    Invoke-Compose ps
    Log "Volume project:"
    docker volume ls --filter "label=com.boilerplate-compile.project=$script:ProjectId"
}

function Cmd-Doctor {
    Log "=== DOCTOR ==="
    Log "Memeriksa akses SSH dan Docker..."
    Write-Host "SSH dan Docker VPS dapat diakses."
    docker version --format "Docker server: {{.Server.Version}}"
    if ($script:ComposeMode -eq "docker-compose-plugin") {
        docker compose version
    } else {
        docker-compose version
    }
}

function Usage {
@"
Penggunaan:
  .\compile.ps1 doctor
  .\compile.ps1 build [--release] [--bin NAMA] [cargo-args]
  .\compile.ps1 run-local [--release] [--bin NAMA] [cargo-args] -- [arg-program]
  .\compile.ps1 dev [--release] [--bin NAMA] [cargo-args] -- [arg-program]
  .\compile.ps1 check [cargo-args]
  .\compile.ps1 test [cargo-args]
  .\compile.ps1 stop
  .\compile.ps1 clean
  .\compile.ps1 purge
  .\compile.ps1 status

Ringkas:
  build      Compile Windows .exe di VPS dan salin ke target/remote/windows.
  run-local  Compile .exe di VPS, salin, lalu jalankan di Windows lokal.
  dev        Compile + jalankan server di container Linux VPS, akses via SSH tunnel.
  check      Cek kode dengan compiler Linux di container VPS.
  test       Jalankan test di container Linux VPS.
  stop       Hentikan aplikasi server di VPS.
  clean      Hapus resource VPS milik project saat ini.
  purge      Hapus semua resource boilerplate-compile di VPS.
"@
}

function Main {
    param([string[]]$Clause)

    Ensure-ProjectId

    $command = if ($Clause.Count -gt 0) { $Clause[0] } else { "help" }
    $rest = if ($Clause.Count -gt 1) { $Clause[1..($Clause.Count - 1)] } else { @() }

    switch ($command) {
        "help" { Usage; exit 0 }
        "-h" { Usage; exit 0 }
        "--help" { Usage; exit 0 }
    }

    Preflight

    switch ($command) {
        "doctor" { Cmd-Doctor }
        "build" { Cmd-Build $rest }
        "run-local" { Cmd-RunLocal $rest }
        "run" { Cmd-RunLocal $rest }
        "dev" { Cmd-Dev $rest }
        "check" { Cmd-Check $rest }
        "test" { Cmd-Test $rest }
        "stop" { Cmd-Stop }
        "clean" { Cmd-Clean }
        "purge" { Cmd-Purge }
        "status" { Cmd-Status }
        default {
            Usage
            Fail "Perintah tidak dikenal: $command"
        }
    }
}

Main $args
