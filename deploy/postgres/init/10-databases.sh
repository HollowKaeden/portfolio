# Создаёт роли и БД проектов в общем Postgres. Пароли берутся из окружения контейнера.
#
# Официальный образ postgres выполняет этот файл сам, но только при первом запуске
# (пустой volume). Чтобы добавить БД нового проекта на работающий сервер, запустить вручную:
#   docker compose exec postgres sh /docker-entrypoint-initdb.d/10-databases.sh
# Скрипт идемпотентный: существующие роли и БД не пересоздаются, пароль роли обновляется.
#
# Файл без exec-бита: entrypoint образа подключает такие .sh через source,
# поэтому здесь нет set -e, ошибки SQL останавливает ON_ERROR_STOP.

create_project_db() {
  name=$1
  pass=$2
  if [ -z "$pass" ]; then
    echo "10-databases.sh: пароль для $name не задан" >&2
    return 1
  fi
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
    -v name="$name" -v pass="$pass" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'name') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'name', :'pass') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'name') \gexec
-- чужие роли к этой БД не подключаются
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'name') \gexec
SQL
  echo "10-databases.sh: БД $name готова"
}

create_project_db bookreviews "${BOOKREVIEWS_DB_PASSWORD:-}"
