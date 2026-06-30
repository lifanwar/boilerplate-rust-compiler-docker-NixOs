Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = (Resolve-Path (Join-Path $ScriptDir "../..")).Path
$ComposeFile = Join-Path $Root ".boilerplate/compose-windows.yml"
$StateDir = Join-Path $Root ".boilerplate/state"
$ConfigFile = if ($env:BOILERPLATE_CONFIG) { $env:BOILERPLATE_CONFIG } else { Join-Path $Root ".boilerplate.env" }
$ImageName = "boilerplate-compile-rust-windows:stable"
$SharedRegistry = "boilerplate-compile-cargo-registry"
$SharedGit = "boilerplate-compile-cargo-git"

Set-Location $Root
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Import-BoilerplateEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
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

$VpsSsh = if ($env:VPS_SSH) { $env:VPS_SSH } else { "" }
$VpsSshPort = if ($env:VPS_SSH_PORT) { $env:VPS_SSH_PORT } else { "22" }
$AppPort = if ($env:APP_PORT) { $env:APP_PORT } else { "3000" }
$LocalPort = if ($env:LOCAL_PORT) { $env:LOCAL_PORT } else { $AppPort }
$RustTarget = if ($env:RUST_TARGET -and $env:RUST_TARGET -ne "auto") { $env:RUST_TARGET } else { "x86_64-pc-windows-gnu" }
$BinaryExt = ".exe"

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
        $name = Safe-Name (Package-Name)
        if (-not $name) {
            $name = Safe-Name (Split-Path -Leaf $Root)
        }
        if (-not $name) {
            $name = "rust-project"
        }

        $bytes = New-Object byte[] 4
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
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
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

    $composeArgs = @(
        "--project-directory", (Join-Path $Root ".boilerplate")
        "-f", $ComposeFile
        "-p", $script:ComposeProjectName
    ) + $Args

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
    Need "cargo"
    Need "docker"
    Need "ssh"
    Need "tar"

    Configure-Remote
    Select-Compose

    ssh -p $VpsSshPort -o BatchMode=yes -o ConnectTimeout=10 $VpsSsh true
    if ($LASTEXITCODE -ne 0) {
        Fail "SSH ke $VpsSsh gagal."
    }

    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker daemon pada VPS tidak dapat diakses oleh $VpsSsh."
    }
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
    $hashFile = Join-Path $StateDir "builder-windows-hash"
    $dockerfile = Join-Path $Root ".boilerplate/docker/Dockerfile.windows"
    if (-not (Test-Path $dockerfile)) {
        $dockerfile = Join-Path $Root ".boilerplate/docker/Dockerfile"
    }

    $currentHash = Get-FileHashText $dockerfile
    $previousHash = ""
    if (Test-Path $hashFile) {
        $previousHash = (Get-Content $hashFile -Raw).Trim()
    }

    docker image inspect $ImageName *> $null
    $imageMissing = $LASTEXITCODE -ne 0

    if ($imageMissing -or $currentHash -ne $previousHash) {
        Write-Host "Membangun image builder di VPS..."
        Invoke-Compose build workspace
        $currentHash | Set-Content -NoNewline $hashFile
    }
}

function Ensure-Workspace {
    Ensure-SharedVolumes
    Ensure-BuilderImage
    Invoke-Compose up -d workspace *> $null
}

function Ensure-Lockfile {
    if (-not (Test-Path (Join-Path $Root "Cargo.lock"))) {
        Write-Host "Membuat Cargo.lock lokal..."
        cargo generate-lockfile
    }
}

function Sync-Source {
    Ensure-Lockfile
    Ensure-Workspace
    Write-Host "Mengirim source ke workspace VPS..."

    tar `
        --exclude="./.git" `
        --exclude="./target" `
        --exclude="./result" `
        --exclude="./dist" `
        --exclude="./.direnv" `
        --exclude="./.boilerplate.env" `
        --exclude="./.boilerplate/state" `
        -C $Root -cf - . |
        Invoke-Compose exec -T workspace sh -lc "find /workspace -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf -- {} + && tar -xf - -C /workspace"
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

    Write-Host "Compile $BinName untuk Windows di VPS..."
    $buildArgs = @("exec", "-T", "workspace", "cargo", "build") +
        $releaseArgs +
        @("--target", $RustTarget, "--bin", $BinName) +
        $script:CargoArgs
    Invoke-Compose @buildArgs

    $outputDir = Join-Path $Root "target/remote/windows/$profile"
    $destination = Join-Path $outputDir "$BinName$BinaryExt"
    $temporary = "$destination.tmp"

    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    Remove-Item -Force -ErrorAction SilentlyContinue $temporary

    Invoke-Compose cp "workspace:/workspace/target/$RustTarget/$profile/$BinName$BinaryExt" $temporary
    Move-Item -Force $temporary $destination

    return $destination
}

function Cmd-Build {
    param([string[]]$Args)
    Parse-BuildArgs $Args
    $binName = Detect-Bin $script:BinRequest
    $output = Remote-BuildAndCopy $binName
    Write-Host "Hasil build: $output"
}

function Cmd-RunLocal {
    param([string[]]$Args)
    Parse-BuildArgs $Args
    $binName = Detect-Bin $script:BinRequest
    $output = Remote-BuildAndCopy $binName

    Write-Host "Menjalankan lokal: $output"
    $programArgs = $script:ProgramArgs
    & $output @programArgs
    exit $LASTEXITCODE
}

function Cmd-Dev {
    param([string[]]$Args)
    Parse-BuildArgs $Args
    $binName = Detect-Bin $script:BinRequest

    Sync-Source

    Write-Host "Tunnel aktif: http://localhost:$LocalPort -> container:$AppPort"
    Write-Host "Aplikasi harus listen pada 0.0.0.0:$AppPort di dalam container."

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
            @("--target", $RustTarget, "--bin", $binName) +
            $script:CargoArgs +
            @("--") +
            $script:ProgramArgs
        Invoke-Compose @runArgs
    } finally {
        if ($tunnel -and -not $tunnel.HasExited) {
            Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Cmd-Check {
    param([string[]]$Args)
    Sync-Source
    Invoke-Compose @(@("exec", "-T", "workspace", "cargo", "check", "--target", $RustTarget) + $Args)
}

function Cmd-Test {
    param([string[]]$Args)
    Sync-Source
    Invoke-Compose @(@("exec", "-T", "workspace", "cargo", "test", "--target", $RustTarget) + $Args)
}

function Cmd-Stop {
    Ensure-Workspace
    Invoke-Compose exec -T workspace sh -lc 'pkill -INT -f "cargo run" 2>/dev/null || true; pkill -INT -f "/workspace/target/.*/(debug|release)/" 2>/dev/null || true'
    Write-Host "Proses aplikasi remote dihentikan. Cache tetap disimpan."
}

function Cmd-Clean {
    Invoke-Compose down --volumes --remove-orphans
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $Root "target/remote")
    Write-Host "Container, network, source mirror, dan target cache project telah dihapus dari VPS."
    Write-Host "Image builder dan cache Cargo bersama tetap disimpan."
}

function Cmd-Purge {
    Cmd-Clean

    $containers = docker ps -aq --filter label=com.boilerplate-compile.managed=true
    if ($containers) {
        docker rm -f @containers *> $null
    }

    $networks = docker network ls -q --filter label=com.boilerplate-compile.managed=true
    if ($networks) {
        docker network rm @networks *> $null
    }

    $volumes = docker volume ls -q --filter label=com.boilerplate-compile.managed=true
    if ($volumes) {
        docker volume rm -f @volumes *> $null
    }

    docker image rm -f $ImageName *> $null
    Write-Host "Seluruh resource boilerplate-compile pada VPS telah dihapus."
}

function Cmd-Status {
    Write-Host "Project ID : $script:ProjectId"
    Write-Host "VPS        : $VpsSsh"
    Write-Host "Docker URI : $env:DOCKER_HOST"
    Write-Host "Target     : $RustTarget"
    Write-Host "Port       : localhost:$LocalPort -> VPS 127.0.0.1:$script:RemotePort -> container:$AppPort"
    Invoke-Compose ps
    docker volume ls --filter "label=com.boilerplate-compile.project=$script:ProjectId"
}

function Cmd-Doctor {
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
  run-local  Compile di VPS, salin, lalu jalankan .exe di Windows lokal.
  dev        Jalankan aplikasi di container VPS dan akses via localhost SSH tunnel.
  clean      Hapus seluruh resource VPS milik project saat ini.
  purge      Hapus semua resource boilerplate-compile, termasuk cache bersama.
"@
}

function Main {
    param([string[]]$Args)

    Ensure-ProjectId

    $command = if ($Args.Count -gt 0) { $Args[0] } else { "help" }
    $rest = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }

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
