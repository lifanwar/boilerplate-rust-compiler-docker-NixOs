# boilerplate-compile

Boilerplate Rust untuk compile di VPS melalui Docker over SSH. Mendukung **dua mode**:
- **Linux mode** (`dev` / `check` / `test`) — binary dijalankan di dalam container Linux VPS.
- **Windows mode** (`build` / `run-local`) — cross-compile ke Windows `.exe` dan dijalankan di lokal.

Dua CLI tersedia: `boilerplate-compile` (bash, untuk NixOS) dan `compile.ps1` (PowerShell, untuk Windows).

## Fitur

- Build Rust di VPS dengan cache `target` per project.
- **Windows**: cross-compile `.exe` via `compile.ps1` (PowerShell).
- **Linux/NixOS**: build native via `boilerplate-compile` (bash).
- Jalankan server di VPS tanpa membuka port publik (SSH tunnel).
- Bersihkan resource satu project atau seluruh builder.

## Prasyarat

### Laptop NixOS

- Nix tersedia.
- SSH key sudah dapat dipakai:

```bash
ssh user@IP_VPS
```

### Windows (PowerShell)

- [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) dengan WSL2 backend.
- SSH client (bawaan Windows 10/11).
- Rust (opsional, hanya untuk `cargo generate-lockfile` lokal).

### VPS (sama untuk semua platform)

- Docker Engine tersedia.
- User SSH dapat menjalankan Docker tanpa `sudo`.

Tes dari VPS:

```bash
docker ps
```

## Instalasi

Clone repository lalu masuk ke folder project:

```bash
git clone https://github.com/USERNAME/boilerplate-compile.git nama-project
cd nama-project
```

Buat konfigurasi lokal:

```bash
cp .boilerplate.env.example .boilerplate.env
```

Isi `.boilerplate.env`:

```env
VPS_SSH=user@IP_VPS
VPS_SSH_PORT=22

APP_PORT=3000
LOCAL_PORT=3000
```

### Linux / NixOS

Masuk ke development shell:

```bash
nix-shell
```

Tes koneksi SSH dan Docker VPS:

```bash
boilerplate-compile doctor
```

### Windows

Pastikan Docker Desktop berjalan, lalu tes koneksi:

```powershell
.\compile.ps1 doctor
```

## Mulai Project

Ubah nama package di `Cargo.toml`:

```toml
[package]
name = "nama-project"
version = "0.1.0"
edition = "2021"
```

Tulis program di:

```text
src/main.rs
```

## Mode

Script secara otomatis memilih mode berdasarkan perintah:

| Perintah | Mode | Compose File | Dockerfile | Hasil |
|---|---|---|---|---|
| `build` | **Windows** | `compose-windows.yml` | `Dockerfile.windows` | `.exe` → `target/remote/windows/` |
| `run-local` | **Windows** | `compose-windows.yml` | `Dockerfile.windows` | `.exe` → dijalankan langsung |
| `dev` | **Linux** | `compose.yml` | `Dockerfile` | Jalan di container VPS |
| `check` | **Linux** | `compose.yml` | `Dockerfile` | Cek kode di Linux |
| `test` | **Linux** | `compose.yml` | `Dockerfile` | Test di Linux |

## Perintah — Linux / NixOS (bash)

### Build di VPS

```bash
boilerplate-compile build
```

Build release:

```bash
boilerplate-compile build --release
```

Hasil binary:

```text
target/remote/debug/nama-project
target/remote/release/nama-project
```

### Build di VPS lalu Jalankan Lokal

Cocok untuk CLI, Slint, atau aplikasi desktop:

```bash
boilerplate-compile run-local
```

Alias:

```bash
boilerplate-compile run
```

Dengan argumen program:

```bash
boilerplate-compile run-local -- --nama Roy
```

### Jalankan Server di VPS

```bash
boilerplate-compile dev
```

Akses dari laptop:

```text
http://localhost:3000
```

Aplikasi di dalam container harus listen pada:

```text
0.0.0.0:3000
```

Port hanya bind ke `127.0.0.1` VPS dan diteruskan melalui SSH tunnel. Port tidak dibuka ke IP publik VPS.

### Check dan Test

```bash
boilerplate-compile check
boilerplate-compile test
```

### Lihat Status

```bash
boilerplate-compile status
```

### Hentikan Aplikasi Remote

```bash
boilerplate-compile stop
```

Container workspace dan cache build tetap disimpan.

### Bersihkan Project Saat Ini

```bash
boilerplate-compile clean
```

Menghapus:
- container project;
- source mirror di VPS;
- cache `target` project;
- network dan volume project;
- binary remote lokal.

Image builder dan cache Cargo bersama tetap disimpan.

### Hapus Seluruh Builder

```bash
boilerplate-compile purge
```

Menghapus seluruh container, volume, network, cache Cargo, dan image milik `boilerplate-compile` pada VPS.

## Perintah — Windows (PowerShell)

Semua perintah dijalankan lewat `compile.ps1`:

### Doctor — Cek Koneksi

```powershell
.\compile.ps1 doctor
```

### Build Windows .exe di VPS

```powershell
.\compile.ps1 build
.\compile.ps1 build --release
```

Hasil binary:

```text
target/remote/windows/debug/nama-project.exe
target/remote/windows/release/nama-project.exe
```

### Build .exe lalu Jalankan di Windows Lokal

```powershell
.\compile.ps1 run-local
.\compile.ps1 run-local -- --nama Roy
```

### Dev — Jalankan Server di Container Linux VPS

```powershell
.\compile.ps1 dev
```

Akses via SSH tunnel di `http://localhost:3000`.

### Check dan Test (Linux compiler di VPS)

```powershell
.\compile.ps1 check
.\compile.ps1 test
```

### Manajemen

```powershell
.\compile.ps1 status
.\compile.ps1 stop
.\compile.ps1 clean
.\compile.ps1 purge
```

## Cara Kerja

```text
source lokal
    ↓ SSH
container Docker di VPS
    ↓
cargo build dengan cache project
    ↓
binary dikirim ke lokal
    ↓
Windows: .exe dijalankan di Windows
Linux:   binary dijalankan di NixOS
         atau server tetap jalan di container VPS via SSH tunnel
```

Build berikutnya lebih cepat karena volume `target` tetap tersedia sampai Anda menjalankan `clean`.

## Struktur

```text
boilerplate-compile/
├── Cargo.toml
├── shell.nix
├── README.md
├── .boilerplate.env.example
├── src/
│   └── main.rs
└── .boilerplate/
    ├── bin/
    │   ├── boilerplate-compile     # CLI bash (Linux / NixOS)
    │   └── compile.ps1             # CLI PowerShell (Windows)
    ├── docker/
    │   ├── Dockerfile              # Linux builder
    │   └── Dockerfile.windows      # Windows cross-compile builder
    ├── compose.yml                 # Linux mode
    ├── compose-windows.yml         # Windows mode
    └── state/
```

## Catatan

- Jangan commit `.boilerplate.env`.
- Jangan simpan private SSH key di repository.
- `Cargo.toml` dan `src/` sudah di-`.gitignore` — buat ulang di setiap clone.
- `clean` hanya menghapus resource project aktif.
- `purge` menghapus seluruh resource `boilerplate-compile` di VPS.
