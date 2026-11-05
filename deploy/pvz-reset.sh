#!/usr/bin/env bash
# Ночной сброс демо ПВЗ-сервиса. Демо публичное (/dummyLogin выдаёт любую роль),
# поэтому раз в сутки данные посетителей удаляются и создаётся эталонный набор:
# три ПВЗ, в Москве одна приёмка открыта (pvz-service: internal/demo).
# Данные демо не ценные, в бэкап проект не входит.
#
#   bash /opt/givemeanoffer/pvz-reset.sh     вручную; cron в 04:10, после сброса Фудграма
#
# Лог cron: backups/pvz-reset.log. Billing сбрасывается первым: журнал и balances
# очищаются, offsets уходят в конец топика. Старые события не начисляются заново.
set -euo pipefail

APP_DIR=/opt/givemeanoffer
cd "$APP_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Остановка обоих писателей исключает гонку со вчерашними outbox-событиями.
# Даже при ошибке reset поднимаем сервисы обратно; pending_reset завершит
# незаконченный перенос offsets при старте billing.
trap 'docker compose --project-directory "$APP_DIR" up -d pvz billing' EXIT
docker compose --project-directory "$APP_DIR" stop pvz billing
log "сброс billing и перевод offsets в конец вчерашнего журнала"
docker compose --project-directory "$APP_DIR" run --rm --no-deps billing demo-reset
log "сброс демо pvz"
docker compose --project-directory "$APP_DIR" run --rm --no-deps pvz demo-reset
log "готово"
