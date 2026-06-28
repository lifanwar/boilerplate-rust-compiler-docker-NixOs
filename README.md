# boilerplate-compile

Boilerplate Rust untuk compile di VPS melalui Docker over SSH. Hasil build dapat dijalankan di NixOS, sementara aplikasi server dapat diakses melalui `localhost` memakai SSH tunnel.

Boilerplate ini juga mendukung `sccache` agar proses build Rust lebih cepat. Cache `target` tetap disimpan per project, sedangkan cache Cargo dan `sccache` dapat dipakai bersama oleh beberapa project.

## Fitur

- Build Rust di VPS.
- Build dilakukan di dalam container Docker.
- Cache `target` per project agar build berikutnya lebih cepat.
- Cache Cargo registry dan Cargo git dipakai bersama.
- Cache compile Rust memakai `sccache`.
- Batas cache `sccache` dapat diatur, misalnya 7 GB.
- Build di VPS lalu jalankan binary di NixOS.
- Jalankan server di VPS tanpa membuka port publik.
- Lihat statistik cache `sccache`.
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

SCCACHE_CACHE_SIZE=7G
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

### Lihat Statistik sccache

```bash
boilerplate-compile sccache-stats
```

Command ini menampilkan statistik cache compile, seperti jumlah request, cache hit, cache miss, dan ukuran cache.

Contoh informasi yang dapat muncul:

```text
Compile requests
Cache hits
Cache misses
Cache size
Max cache size
```

Build pertama biasanya masih banyak `cache miss`. Build berikutnya akan lebih cepat jika dependency, target, toolchain, dan fitur build masih sama.

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

Image builder, cache Cargo bersama, dan cache `sccache` bersama tetap disimpan.

### Hapus Seluruh Builder

```bash
boilerplate-compile purge
```

Menghapus seluruh container, volume, network, cache Cargo, cache `sccache`, dan image milik `boilerplate-compile` pada VPS.

Gunakan perintah ini hanya jika ingin benar-benar menghapus seluruh resource builder.

## Cara Kerja

```text
source lokal
    ↓ SSH
container Docker di VPS
    ↓
cargo build dengan cache target project
    ↓
rustc dipanggil melalui sccache
    ↓
binary dikirim ke NixOS
    ↓
dijalankan lokal atau tetap berjalan di VPS
```

Build berikutnya lebih cepat karena beberapa cache tetap tersedia di VPS:

```text
1. target cache per project
2. Cargo registry cache bersama
3. Cargo git cache bersama
4. sccache compile cache bersama
```

## Cara Kerja Cache

### Cache target

Cache `target` disimpan per project.

Contoh:

```text
Project A memiliki target cache sendiri
Project B memiliki target cache sendiri
```

Ini membuat setiap project tetap rapi dan tidak saling mencampur hasil build.

### Cache Cargo

Cache Cargo dipakai bersama.

Contoh:

```text
boilerplate-compile-cargo-registry
boilerplate-compile-cargo-git
```

Jika Project A dan Project B memakai dependency yang sama, dependency tidak perlu diunduh ulang.

### Cache sccache

Cache `sccache` dipakai bersama oleh beberapa project.

Contoh:

```text
boilerplate-compile-sccache
```

Jika Project A dan Project B memakai crate yang sama, versi yang sama, target yang sama, toolchain yang sama, dan fitur yang sama, Project B bisa mendapat cache hit dari hasil compile Project A.

Namun, kode utama Project A dan Project B tetap akan dicompile sendiri jika source code-nya berbeda.

## Batas Cache sccache

Ukuran cache `sccache` dapat diatur melalui `.boilerplate.env`:

```env
SCCACHE_CACHE_SIZE=7G
```

Jika cache sudah melewati batas, `sccache` akan menghapus cache lama agar ukuran tetap terkendali.

Nilai ini berlaku untuk cache `sccache` bersama, bukan per project.

Contoh:

```text
Project A + Project B + Project C berbagi total cache sccache 7 GB
```

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

## Resource Docker

Boilerplate ini membuat beberapa resource Docker di VPS.

Resource per project:

```text
workspace container
source volume
target volume
network
```

Resource bersama:

```text
boilerplate-compile-cargo-registry
boilerplate-compile-cargo-git
boilerplate-compile-sccache
builder image
```

Dengan desain ini, setiap project tetap punya workspace sendiri, tetapi tetap bisa mendapat keuntungan dari cache bersama.

## Catatan

- Jangan commit `.boilerplate.env`.
- Jangan simpan private SSH key di repository.
- `clean` hanya menghapus resource project aktif.
- `clean` tidak menghapus cache Cargo bersama dan cache `sccache` bersama.
- `purge` menghapus seluruh resource `boilerplate-compile` di VPS.
- Cache `sccache` lokal bersama lebih aman dipakai untuk build satu per satu.
- Jika ingin build banyak project secara paralel, pertimbangkan cache `sccache` per project atau backend remote seperti S3-compatible storage.
