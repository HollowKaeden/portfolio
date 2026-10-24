#!/usr/bin/env bash
# Ночной сброс демо ПВЗ-сервиса. Демо публичное (/dummyLogin выдаёт любую роль),
# поэтому раз в сутки данные посетителей удаляются и создаётся эталонный набор:
# три ПВЗ, в Москве одна приёмка открыта (pvz-service: internal/demo).
# Данные демо не ценные, в бэкап проект не входит.
#
#   bash /opt/givemeanoffer/pvz-reset.sh     вручную; cron в 04:10, после сброса Фудграма
#
# Лог cron: backups/pvz-reset.log. Когда появится billing, он сбрасывается первым:
# его журнал начислений ссылается на ПВЗ из pvz.
set -euo pipefail

APP_DIR=/opt/givemeanoffer
cd "$APP_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

log "сброс демо pvz"
# pvz пишет в лог одну строку JSON: итог или ошибку
docker compose --project-directory "$APP_DIR" exec -T pvz pvz demo-reset
log "готово"
