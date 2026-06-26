# boilerplate-compile

Boilerplate Rust untuk compile di VPS melalui Docker over SSH. Hasil build dapat dijalankan di NixOS, sementara aplikasi server dapat diakses melalui `localhost` memakai SSH tunnel.

## Fitur

- Build Rust di VPS.
- Cache `target` per project agar build berikutnya lebih cepat.
- Build di VPS lalu jalankan binary di NixOS.
- Jalankan server di VPS tanpa membuka port publik.
- Bersihkan resource satu project atau seluruh builder.

## Prasyarat

### Laptop NixOS

- Nix tersedia.
- SSH key sudah dapat dipakai:

```bash
ssh user@IP_VPS
```

### VPS

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

Masuk ke development shell:

```bash
nix-shell
```

Tes koneksi SSH dan Docker VPS:

```bash
boilerplate-compile doctor
```

## Mulai Project

Ubah nama package di `Cargo.toml`:

```toml
[package]
name = "nama-project"
version = "0.1.0"
edition = "2024"
```

Tulis program di:

```text
src/main.rs
```

## Perintah

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

## Cara Kerja

```text
source lokal
    ↓ SSH
container Docker di VPS
    ↓
cargo build dengan cache project
    ↓
binary dikirim ke NixOS
    ↓
dijalankan lokal atau tetap berjalan di VPS
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
    │   └── boilerplate-compile
    ├── docker/
    │   └── Dockerfile
    ├── compose.yml
    └── state/
```

## Catatan

- Jangan commit `.boilerplate.env`.
- Jangan simpan private SSH key di repository.
- `clean` hanya menghapus resource project aktif.
- `purge` menghapus seluruh resource `boilerplate-compile` di VPS.
