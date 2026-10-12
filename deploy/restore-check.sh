#!/usr/bin/env bash
# Проверка, что внешний бэкап реально восстанавливается.
# Берёт последний снапшот restic из Yandex Object Storage, разворачивает дамп BookReviews
# во временном Postgres без сети и сравнивает число книг и обложек с рабочей базой.
# Рабочие сервисы и данные не трогает. Раз в месяц (вручную или по cron).
#
# Запуск: bash /opt/givemeanoffer/restore-check.sh
set -euo pipefail

APP_DIR=/opt/givemeanoffer
RESTIC_IMAGE=restic/restic:0.19.1
PG_IMAGE=postgres:16
PROJECT=givemeanoffer
CHECK_PG=restore-check-pg

cd "$APP_DIR"
set -a; . ./.env; set +a
[ -n "${RESTIC_REPOSITORY:-}" ] || { echo "RESTIC_REPOSITORY не задан"; exit 1; }

work=$(mktemp -d /tmp/restore-check.XXXXXX)
chmod 755 "$work"
cleanup() {
  docker rm -f "$CHECK_PG" >/dev/null 2>&1 || true
  # файлы из контейнера restic принадлежат root, удаляем тоже из контейнера
  docker run --rm -v "$work":/w alpine:3 sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "== Последний снапшот"
docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
  -v "$work":/restore "$RESTIC_IMAGE" \
  snapshots latest --compact
docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
  -v "$work":/restore "$RESTIC_IMAGE" \
  restore latest --target /restore --quiet

dump=$work/data/db/bookreviews.dump
[ -s "$dump" ] || { echo "ПРОВАЛ: в снапшоте нет bookreviews.dump"; exit 1; }

echo "== Разворачиваю дамп во временном Postgres (без сети)"
docker run -d --name "$CHECK_PG" --network none -e POSTGRES_PASSWORD=check \
  -v "$dump":/bookreviews.dump:ro "$PG_IMAGE" >/dev/null
for _ in $(seq 1 60); do
  [ "$(docker logs "$CHECK_PG" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] && break
  sleep 1
done
docker exec "$CHECK_PG" createdb -U postgres bookreviews
docker exec "$CHECK_PG" pg_restore -U postgres -d bookreviews --no-owner --no-privileges /bookreviews.dump

count() { docker exec "$1" psql -U postgres -d bookreviews -tAc "$2"; }
q_books="select count(*) from books"
q_covers="select count(*) from books where cover_filename is not null"

restored_books=$(count "$CHECK_PG" "$q_books")
restored_cover_rows=$(count "$CHECK_PG" "$q_covers")
restored_cover_files=$(find "$work/data/bookreviews_uploads" -type f | wc -l)
live_books=$(docker compose exec -T postgres psql -U postgres -d bookreviews -tAc "$q_books")
live_cover_files=$(docker run --rm -v ${PROJECT}_bookreviews_uploads:/d:ro alpine:3 sh -c 'find /d -type f | wc -l')

echo "== Итог"
printf '  книг:     в бэкапе %s, сейчас в работе %s\n' "$restored_books" "$live_books"
printf '  обложек:  в бэкапе файлов %s (в БД ссылок %s), сейчас в работе %s\n' \
  "$restored_cover_files" "$restored_cover_rows" "$live_cover_files"

# Снапшот ночной, поэтому небольшое расхождение с рабочей базой нормально.
# Провал: бэкап пустой при непустой базе или в БД есть обложки, которых нет в файлах.
if [ "$live_books" -gt 0 ] && [ "$restored_books" -eq 0 ]; then
  echo "ПРОВАЛ: в бэкапе 0 книг"; exit 1
fi
if [ "$restored_cover_files" -lt "$restored_cover_rows" ]; then
  echo "ПРОВАЛ: файлов обложек меньше, чем ссылок на них"; exit 1
fi
echo "OK: бэкап восстанавливается"
