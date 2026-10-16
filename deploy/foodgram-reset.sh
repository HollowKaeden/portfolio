#!/usr/bin/env bash
# Ежедневный сброс Фудграма к эталону. Регистрация открыта, посетители заводят аккаунты,
# публикуют рецепты и грузят картинки; раз в сутки БД и медиа возвращаются к эталону.
#
#   bash /opt/givemeanoffer/foodgram-reset.sh snapshot   текущее состояние → эталон
#   bash /opt/givemeanoffer/foodgram-reset.sh            БД и медиа ← эталон (cron, см. CLAUDE.md)
#
# Эталон лежит в backups/foodgram-seed/: деплой (rsync --delete) папку backups/ не трогает,
# а ротация в backup.sh удаляет только папки с датой в имени. Снимать эталон заново после
# каждого осознанного изменения (новый рецепт, смена пароля), иначе ночью оно откатится.
# Лог cron: backups/foodgram-reset.log.
set -euo pipefail
umask 077 # в дампе хеши паролей и токены

APP_DIR=/opt/givemeanoffer
SEED_DIR=$APP_DIR/backups/foodgram-seed
PROJECT=givemeanoffer
MEDIA_VOLUME=${PROJECT}_foodgram_media

cd "$APP_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
compose() { docker compose --project-directory "$APP_DIR" "$@"; }
psql_foodgram() { compose exec -T postgres psql -U postgres -d foodgram -tAc "$1"; }

counts() {
  psql_foodgram "select format('пользователей %s, рецептов %s',
    (select count(*) from recipes_customuser), (select count(*) from recipes_recipe))"
}

snapshot() {
  mkdir -p "$SEED_DIR"
  # сначала во временные файлы: недописанный эталон не должен заменить рабочий
  compose exec -T postgres pg_dump -U postgres -Fc foodgram >"$SEED_DIR/foodgram.dump.new"
  docker run --rm -v "$MEDIA_VOLUME":/media:ro alpine:3 tar -C /media -cf - . >"$SEED_DIR/media.tar.new"
  mv "$SEED_DIR/foodgram.dump.new" "$SEED_DIR/foodgram.dump"
  mv "$SEED_DIR/media.tar.new" "$SEED_DIR/media.tar"
  log "эталон сохранён: $(counts), дамп $(du -h "$SEED_DIR/foodgram.dump" | cut -f1), медиа $(du -h "$SEED_DIR/media.tar" | cut -f1)"
}

reset() {
  if [ ! -s "$SEED_DIR/foodgram.dump" ] || [ ! -s "$SEED_DIR/media.tar" ]; then
    log "ОШИБКА: нет эталона в $SEED_DIR, сначала: $0 snapshot"
    exit 1
  fi
  log "сброс, было: $(counts)"

  # Бэкенд стоит, пока идёт восстановление, чтобы никто не писал в БД. Что бы ни случилось
  # дальше, на выходе он запускается снова (gateway всё это время отдаёт фронт, API 502).
  compose stop foodgram-backend
  trap 'compose up -d foodgram-backend' EXIT

  # --clean --if-exists: таблицы из дампа пересоздаются и заполняются его данными.
  # Одна транзакция: при ошибке БД остаётся как была.
  compose exec -T postgres pg_restore -U postgres -d foodgram \
    --clean --if-exists --single-transaction --exit-on-error <"$SEED_DIR/foodgram.dump"

  docker run --rm -i -v "$MEDIA_VOLUME":/media alpine:3 \
    sh -c 'find /media -mindepth 1 -delete && tar -C /media -xf -' <"$SEED_DIR/media.tar"

  trap - EXIT
  compose up -d --wait foodgram-backend
  log "готово, стало: $(counts)"
}

case "${1:-reset}" in
  snapshot) snapshot ;;
  reset) reset ;;
  *) echo "использование: $0 [snapshot|reset]" >&2; exit 2 ;;
esac
