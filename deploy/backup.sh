#!/usr/bin/env bash
# Ежедневный бэкап: дампы БД и обложки BookReviews.
#   1) локально в backups/<дата>/, хранятся последние KEEP_LOCAL (быстрый откат после ошибки в данных);
#   2) restic → Yandex Object Storage (копия вне сервера, зашифрована на сервере).
# Во внешнюю копию идёт всё, кроме медиа Фудграма (чтобы уложиться в бесплатный 1 ГБ).
#
# Запуск: bash /opt/givemeanoffer/backup.sh   (cron: см. CLAUDE.md, раздел «Команды»)
# Код выхода не 0, если что-то не получилось; подробности в backups/backup.log.
set -euo pipefail
umask 077 # дампы содержат данные: читать может только владелец

APP_DIR=/opt/givemeanoffer
BACKUP_DIR=$APP_DIR/backups
KEEP_LOCAL=7
RESTIC_IMAGE=restic/restic:0.19.1
PROJECT=givemeanoffer

cd "$APP_DIR"
set -a; . ./.env; set +a

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
compose() { docker compose --project-directory "$APP_DIR" "$@"; }

ts=$(date +%F_%H%M)
dir=$BACKUP_DIR/$ts
mkdir -p "$dir"
log "старт, $dir"

# --- 1. Дампы БД (custom-формат: сжат, восстанавливается через pg_restore)
dbs=$(compose exec -T postgres psql -U postgres -tAc \
  "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1")
for db in $dbs; do
  compose exec -T postgres pg_dump -U postgres -Fc "$db" >"$dir/$db.dump"
  log "дамп $db: $(du -h "$dir/$db.dump" | cut -f1)"
done
[ -s "$dir/bookreviews.dump" ] || { log "ОШИБКА: нет дампа bookreviews"; exit 1; }

# --- 2. Обложки BookReviews (картинки уже сжаты, поэтому tar без gzip)
docker run --rm -v ${PROJECT}_bookreviews_uploads:/data:ro alpine:3 tar -C /data -cf - . \
  >"$dir/bookreviews_uploads.tar"
log "обложки: $(du -h "$dir/bookreviews_uploads.tar" | cut -f1)"

# --- 3. Локальная ротация: оставить последние KEEP_LOCAL
ls -1d "$BACKUP_DIR"/20??-??-??_???? | head -n -"$KEEP_LOCAL" | xargs -r rm -rf
log "локально хранится копий: $(ls -1d "$BACKUP_DIR"/20??-??-??_???? | wc -l)"

# --- 4. Внешняя копия через restic
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  log "ВНИМАНИЕ: RESTIC_REPOSITORY не задан, внешняя копия пропущена"
  exit 2
fi

# Пути внутри контейнера постоянные (/data/...), чтобы restic видел одни и те же файлы
# изо дня в день и загружал только изменения. Обложки берём прямо из volume.
restic() {
  docker run --rm -i \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    -v "$dir":/data/db:ro \
    -v ${PROJECT}_bookreviews_uploads:/data/bookreviews_uploads:ro \
    -v "$BACKUP_DIR/restic-cache":/root/.cache/restic \
    --hostname "$PROJECT" \
    "$RESTIC_IMAGE" "$@"
}

if ! restic cat config >/dev/null 2>&1; then
  log "репозиторий restic не найден, создаю"
  restic init
fi

restic backup --quiet --tag daily /data/db /data/bookreviews_uploads
restic forget --quiet --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
log "restic: снапшотов $(restic snapshots --json | grep -o '"short_id"' | wc -l), $(restic stats --mode raw-data 2>/dev/null | grep -i 'total size' | sed 's/.*: *//')"

log "готово"
