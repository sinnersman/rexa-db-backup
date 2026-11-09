# Rexa-DB-Backup

CLI auto-backup MySQL/MariaDB + PostgreSQL dalam satu script bash. Deteksi OS otomatis (Alpine `apk` / Ubuntu `apt`) dan tiga mode koneksi.

Copyright Risky Setiawan — MIT License.

## Mode

| Mode | Kapan dipakai |
|------|---------------|
| `docker` | DB jalan sebagai container (via `podman`/`docker exec`) |
| `host` | Server backup nembak server DB via TCP (`host:port`) |
| `socket` | DB lokal via unix socket (XAMPP / MySQL standar) |

## Pakai

```bash
# Alpine
apk add --no-cache bash
curl -fsSL https://github.com/sinnersman/rexa-db-backup/releases/latest/download/rexa-db-backup.sh -o /usr/local/bin/rexa-db-backup
chmod +x /usr/local/bin/rexa-db-backup
sudo rexa-db-backup
```

Di TUI: menu `1` (install deps) → `2` (isi mode + kredensial + pilih DB **kecil** biar cepat) → `3` (tes koneksi sampai hijau) → `4` (backup) → `7` (cron ON).

Non-interaktif:

```bash
rexa-db-backup test          # tes TCP + auth
rexa-db-backup backup-pg     # backup PG saja
rexa-db-backup backup-mysql  # backup MySQL saja
rexa-db-backup run-backup    # backup semua (dipakai cron)
```

Config di `/etc/db-autobackup/config.json` (chmod 600), hasil di `/var/backups/db-backup`, log `/var/log/db-autobackup.log`.

## Rilis otomatis

Setiap push ke `main` menaikkan patch di `VERSION`, membuat tag `vX.Y.Z`, dan menerbitkan GitHub Release berisi `rexa-db-backup.sh` (lihat `.github/workflows/release.yml`).
