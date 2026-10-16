#!/usr/bin/env bash
# Ежедневный бэкап BookReviews: дамп БД и обложки.
#   1) локально в backups/<дата>/, хранятся последние KEEP_LOCAL (быстрый откат после ошибки в данных);
#   2) restic → Yandex Object Storage (копия вне сервера, зашифрована на сервере).
# Фудграм каждую ночь сбрасывается к эталону (foodgram-reset.sh), поэтому его текущая БД
# не бэкапится: во внешнюю копию идёт только эталон (backups/foodgram-seed/, дамп и медиа).
# Пока эталон не меняется, restic его не перезагружает.
#
# Запуск: bash /opt/givemeanoffer/backup.sh   (cron: см. CLAUDE.md, раздел «Команды»)
# Код выхода не 0, если что-то не получилось; подробности в backups/backup.log.
set -euo pipefail
umask 077 # дампы содержат данные: читать может только владелец

APP_DIR=/opt/givemeanoffer
BACKUP_DIR=$APP_DIR/backups
SEED_DIR=$BACKUP_DIR/foodgram-seed # эталон Фудграма, снимает foodgram-reset.sh snapshot
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

# --- 1. Дамп БД (custom-формат: сжат, восстанавливается через pg_restore)
compose exec -T postgres pg_dump -U postgres -Fc bookreviews >"$dir/bookreviews.dump"
[ -s "$dir/bookreviews.dump" ] || { log "ОШИБКА: нет дампа bookreviews"; exit 1; }
log "дамп bookreviews: $(du -h "$dir/bookreviews.dump" | cut -f1)"

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

# Без эталона Фудграма книги всё равно уходят во внешнюю копию, а ошибка будет в конце.
# Монтируем папку только если она есть: иначе docker создал бы её от root.
seed_mount=() seed_path=() seed_missing=
if [ -s "$SEED_DIR/foodgram.dump" ] && [ -s "$SEED_DIR/media.tar" ]; then
  seed_mount=(-v "$SEED_DIR":/data/foodgram-seed:ro) seed_path=(/data/foodgram-seed)
else
  seed_missing=1
fi

# Пути внутри контейнера постоянные (/data/...), чтобы restic видел одни и те же файлы
# изо дня в день и загружал только изменения. Обложки берём прямо из volume.
restic() {
  docker run --rm -i \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    -v "$dir":/data/db:ro \
    -v ${PROJECT}_bookreviews_uploads:/data/bookreviews_uploads:ro \
    "${seed_mount[@]}" \
    -v "$BACKUP_DIR/restic-cache":/root/.cache/restic \
    --hostname "$PROJECT" \
    "$RESTIC_IMAGE" "$@"
}

if ! restic cat config >/dev/null 2>&1; then
  log "репозиторий restic не найден, создаю"
  restic init
fi

# tar обложек нужен только локально: во внешнюю копию обложки идут файлами прямо из volume,
# иначе они попали бы туда дважды.
restic backup --quiet --tag daily --exclude /data/db/bookreviews_uploads.tar \
  /data/db /data/bookreviews_uploads "${seed_path[@]}"
# Без --group-by restic группирует снапшоты ещё и по набору путей: после смены путей
# (2026-10-16 добавился эталон Фудграма) старые снапшоты остались бы отдельной группой навсегда.
restic forget --quiet --prune --group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6
log "restic: снапшотов $(restic snapshots --json | grep -o '"short_id"' | wc -l), $(restic stats --mode raw-data 2>/dev/null | grep -i 'total size' | sed 's/.*: *//')"

if [ -n "$seed_missing" ]; then
  log "ОШИБКА: нет эталона Фудграма в $SEED_DIR, во внешнюю копию он не попал" \
    "(снять: bash $APP_DIR/foodgram-reset.sh snapshot)"
  exit 1
fi
log "готово"
