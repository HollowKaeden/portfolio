# portfolio

[![build-deploy](https://github.com/HollowKaeden/portfolio/actions/workflows/build-deploy.yml/badge.svg)](https://github.com/HollowKaeden/portfolio/actions/workflows/build-deploy.yml)

Мой сайт-портфолио [givemeanoffer.ru](https://givemeanoffer.ru) и вся инфраструктура, на которой
работают мои пет-проекты. Идея сайта: проекты можно открыть и потрогать вживую, а не только
прочитать про них.

| Что | Где | Репозиторий |
|-----|-----|-------------|
| Портфолио (Astro, статика) | [givemeanoffer.ru](https://givemeanoffer.ru) | этот |
| Мои книги (FastAPI, PostgreSQL) | [books.givemeanoffer.ru](https://books.givemeanoffer.ru) | [BookReviews](https://github.com/HollowKaeden/BookReviews) |
| Фудграм (Django, DRF, React) | [foodgram.givemeanoffer.ru](https://foodgram.givemeanoffer.ru) | [foodgram-st](https://github.com/HollowKaeden/foodgram-st) |
| ПВЗ-сервис (Go, gRPC, Kafka) | [pvz.givemeanoffer.ru](https://pvz.givemeanoffer.ru) | [pvz-service](https://github.com/HollowKaeden/pvz-service) |
| Генератор нагрузки (Go): форма, которая нагружает этот же сервер | [givemeanoffer.ru/projects/http-loadgen/](https://givemeanoffer.ru/projects/http-loadgen/) | [http-loadgen](https://github.com/HollowKaeden/http-loadgen) |

## Как это устроено

ПВЗ-сервис и начисления используют один образ `ghcr.io/hollowkaeden/pvz-service`, но разные бинарники и БД. `/billing/*` на поддомене ПВЗ направляется в billing. Ему заданы 64 МиБ RAM и три соединения с Postgres. Kafka и порты метрик снаружи недоступны.

Перед первым деплоем billing добавьте случайный URL-безопасный `PVZ_BILLING_DB_PASSWORD` в серверный `/opt/givemeanoffer/.env`. Деплой создаст отдельную роль и БД `pvz_billing`; приложение применит свои миграции. Сначала должен пройти CI `pvz-service` с публикацией образа, содержащего оба бинарника, затем пуш конфигурации `portfolio`. После деплоя проверьте `/billing/health`, начисление за закрытую приёмку, память и отсутствие OOM. Подробности API и rebuild — в README `pvz-service`.

Ночной `deploy/pvz-reset.sh` кратко останавливает pvz и billing: сначала очищает начисления и переводит offsets в конец старого журнала Kafka, затем сбрасывает pvz и запускает сервисы. Эталонные начисления приходят через обычный outbox. Данные этого демо в бэкап не входят.

Один VPS (1 vCPU, 2 ГБ RAM, Ubuntu 24.04), один Docker Compose, один Caddy впереди.
Каждый проект живёт на своём поддомене и работает в корне, как локально, без переделки
под префикс.

Caddy принимает весь трафик на 443 порту, сам получает сертификаты для каждого имени
и раздаёт запросы по контейнерам:

| Адрес | Сервис |
|-------|--------|
| `givemeanoffer.ru` | статика портфолио (образ этого репозитория) |
| `givemeanoffer.ru/loadgen/api/*` | `loadgen-web` (Go), нагружает цели из белого списка |
| `www.givemeanoffer.ru` | редирект на `givemeanoffer.ru` |
| `books.givemeanoffer.ru` | `bookreviews` (FastAPI) |
| `foodgram.givemeanoffer.ru` | `foodgram-gateway` (nginx со сборкой React), API и админку проксирует в `foodgram-backend` (Django) |
| `pvz.givemeanoffer.ru` | `pvz` (Go): API приёмки товаров на ПВЗ и Swagger UI на `/docs/` |
| `pvz.givemeanoffer.ru/billing/*` | `billing` (Go): балансы, журнал начислений и ставки |

BookReviews, Фудграм и ПВЗ-сервис хранят данные в одном общем PostgreSQL, у каждого своя база и свой пользователь.

Репозитории связаны только через Docker-образы, без git-подмодулей:

1. Каждый пет-проект на пуш в `main` сам собирает образ в GitHub Actions и пушит его в реестр,
   а в конце шлёт `repository_dispatch` в этот репозиторий.
2. Здесь workflow [build-deploy.yml](.github/workflows/build-deploy.yml) копирует `deploy/` на сервер,
   делает `docker compose pull && up -d` и проверяет health всех сервисов. При пуше в этот репозиторий
   перед деплоем ещё собирается образ сайта.
3. На сервере ничего не собирается: одного ядра на это не хватит.

Несколько решений, которые здесь стоит отметить:

- **Домен нигде не захардкожен.** Он задаётся переменной `DOMAIN` в `.env` на сервере: Caddyfile
  берёт `{$DOMAIN}`, compose подставляет его в настройки проектов, сайт получает его при сборке,
  а в контенте ссылки на демо записаны как поддомен. Чтобы сменить домен, достаточно поменять переменную и DNS и передеплоить.
- **Сети.** `proxy` для Caddy и приложений, `db` внутренняя (только приложения и Postgres, Caddy
  в неё не входит). У Caddy фиксированный адрес, и приложения доверяют `X-Forwarded-*` только
  от него. Автоматические адреса выдаются из верхней половины подсети, чтобы новый контейнер
  не занял адрес Caddy, пока тот пересоздаётся (было один раз, сайт лёг).
- **Caddyfile не в образе.** Он монтируется папкой из `deploy/caddy/`, поэтому правка роутинга
  деплоится без пересборки. Именно папкой, а не файлом: rsync заменяет файл, и bind-mount
  файла продолжал бы видеть старую версию.
- **Реестры.** Маленькие образы (сайт, BookReviews, loadgen-web, pvz-service) лежат в ghcr, большие образы
  Фудграма в Docker Hub: с сервера в России ghcr отдаёт ~0.2 МБ/с, Docker Hub ~30 МБ/с.
- **Postgres общий** на все проекты: у каждого своя БД и свой пользователь, `shared_buffers=128MB`,
  `max_connections=40`. Скрипт создания ролей и БД идемпотентный и запускается на каждом деплое,
  потому что штатный init образа выполняется только на пустом volume, а новые проекты добавляются
  на живой сервер.
- **Фудграм с открытой регистрацией** каждую ночь сбрасывается к эталону: всё, что за день
  наделали посетители, исчезает. Регистрация и логин под троттлингом, размер картинок ограничен
  на трёх уровнях (Caddy, nginx, Django).

### Форма нагрузки

На странице [http-loadgen](https://givemeanoffer.ru/projects/http-loadgen/) посетитель может
нагрузить настоящий сервер и смотреть живой график RPS и латентности. Чтобы сайт при этом не лёг:

- цели только из белого списка читающих GET-ручек ([deploy/loadgen/targets.json](deploy/loadgen/targets.json)),
  URL, метод и заголовки с клиента не принимаются;
- нагрузка не больше 50% от измеренного максимума цели (`max_rps`: наибольший RPS, при котором
  p99 ≤ 500 мс и ошибок < 1%, меряется калибровкой на этом же сервере);
- один прогон за раз, до 15 с, потом пауза 3 минуты на всех, плюс лимит на IP;
- аварийный тормоз останавливает прогон, если в скользящем окне растут ошибки или p95.

Запросы идут не через интернет, а по внутренней сети Docker на Caddy: у его контейнера сетевые
алиасы с именами сайтов. Поэтому loadgen ходит по настоящим `https://`-адресам и меряет всю цепочку:
TLS, прокси, приложение и БД. На сайте это единственный кусок JS: графики на inline-SVG,
без библиотек ([LoadgenForm.astro](site/src/components/LoadgenForm.astro)).

## Структура

```
site/                         сайт на Astro + TypeScript, статическая сборка
  src/content/site.yaml       весь текст сайта: профиль, проекты, достижения
  src/content.config.ts       схема контента (zod)
  src/components/             секции страницы и форма нагрузки
  src/assets/projects/        скриншоты и миниатюры проектов (Astro сжимает в WebP)
  public/                     иконки, картинка для превью ссылок, резюме
  dev/loadgen-proxy.mjs       прокси /loadgen/api на локальный loadgen-web в dev-режиме
design/                       выгрузка макета из Figma: tokens.md, фреймы, скрипт выгрузки
deploy/                       всё, что копируется на сервер в /opt/givemeanoffer
  compose.yaml                все сервисы прода
  caddy/Caddyfile             роутинг по именам хостов
  postgres/init/              создание БД и ролей проектов
  loadgen/targets.json        белый список целей формы нагрузки и их max_rps
  prometheus/prometheus.yml   сбор метрик приложений, хоста, HTTPS и бэкапов
  blackbox/blackbox.yml       HTTPS-проверки и проверка сертификатов
  monitoring-prepare.py      цели HTTPS из DOMAIN и начальное состояние метрик бэкапа
  backup-metrics.py          атомарная публикация результата backup.sh
  prometheus-check.py         проверка реального сбора после деплоя
  .env.example                переменные окружения (секреты только на сервере)
  bootstrap-server.sh         первичная настройка чистого VPS
  backup.sh                   ежедневный бэкап, локально и в Yandex Object Storage
  restore-check.sh            проверка, что бэкап восстанавливается
  foodgram-reset.sh           ежедневный сброс Фудграма к эталону
  pvz-reset.sh                ежедневный сброс демо ПВЗ-сервиса
Dockerfile                    сборка сайта в образ Caddy со статикой
.github/workflows/build-deploy.yml   сборка образа сайта и деплой
```

## Сайт

Весь текст лежит в [site/src/content/site.yaml](site/src/content/site.yaml) и проверяется схемой при
сборке, в компонентах текста про меня нет. Чтобы добавить проект на сайт, достаточно новой записи в `projects`:

```yaml
- slug: bookreviews                 # страница /projects/bookreviews/
  title: Мои книги
  summary: строка в списке проектов
  description: подробнее, для страницы проекта   # необязательно
  stack: [FastAPI, PostgreSQL, Docker]
  repo: https://github.com/HollowKaeden/BookReviews
  preview: ../assets/projects/bookreviews.png        # необязательно, скриншот 16:10
  thumb: ../assets/projects/bookreviews-thumb.png    # необязательно, квадрат для списка
  demo: { type: link, subdomain: books }             # или { type: loadgen-form }
```

Стили на CSS-переменных, значения из [design/tokens.md](design/tokens.md), который выгружен
из макета в Figma через REST API ([design/scripts/figma.mjs](design/scripts/figma.mjs)).

Локально:

```sh
cd site
npm install
npm run dev      # http://localhost:4321
npm run build    # astro check + сборка в dist/
```

Чтобы форма нагрузки работала в dev-режиме, рядом нужен `loadgen-web` из репозитория
[http-loadgen](https://github.com/HollowKaeden/http-loadgen): dev-сервер проксирует `/loadgen/api`
на `127.0.0.1:8080`.

```sh
# в http-loadgen, со своим targets.json, где цели смотрят на локальный сайт
go run ./cmd/loadgen-web serve -listen 127.0.0.1:8080 -targets targets.local.json
# в site: собранный сайт как цель нагрузки на :4322, форма на npm run dev (:4321)
npm run build && npx astro preview --port 4322
```

## Сервер

### Первичная настройка

1. Создать VPS с Ubuntu 24.04 и выполнить под root:
   ```sh
   bash bootstrap-server.sh setup "ssh-ed25519 AAAA... ключ"
   ```
   Скрипт создаёт пользователя `deploy`, ставит Docker из официального репозитория, ufw (22, 80, 443),
   swap, unattended-upgrades и проверяет доступ к реестрам.
2. В отдельном терминале убедиться, что `ssh deploy@<ip>` пускает по ключу, и только потом:
   ```sh
   bash bootstrap-server.sh harden-ssh    # выключает вход по паролю и root по SSH
   ```
3. DNS: A-записи `@` и `*` на IP сервера. Wildcard покрывает `www`, `books`, `foodgram` и будущие
   поддомены. Сертификаты Caddy выпускает только для хостов, явно перечисленных в Caddyfile.
4. Скопировать `deploy/.env.example` в `/opt/givemeanoffer/.env` и заполнить.
5. В GitHub: секреты `VPS_HOST`, `VPS_SSH_KEY` (отдельный ключ только для CI), `VPS_KNOWN_HOSTS`;
   переменные `VPS_USER`, `DOMAIN`. Запустить workflow `build-deploy` вручную.

Фудграму после первого деплоя нужны ингредиенты и суперпользователь:

```sh
cd /opt/givemeanoffer
docker compose exec foodgram-backend python manage.py load_ingredients
docker compose exec foodgram-backend python manage.py createsuperuser
```

### Деплой

| Событие | Что происходит |
|---------|----------------|
| push в `main` (сайт, `deploy/`, Dockerfile) | сборка образа сайта, затем деплой |
| `repository_dispatch` типа `deploy` из пет-проекта | сразу деплой с новыми образами |
| ручной запуск | сразу деплой |

Деплой не стартует при упавшей сборке, прогоны идут строго по очереди. После `up -d` workflow
перечитывает Caddyfile, конфигурации Prometheus и Blackbox Exporter, перезапускает `loadgen-web` (он читает `targets.json` при старте) и проверяет
главную, редирект с `www`, `/health` и `/ready` BookReviews, API Фудграма, `/loadgen/api/status`,
`/health` и Swagger UI ПВЗ-сервиса. Конфигурация Prometheus проверяется `promtool` до сборки сайта
и на сервере. Blackbox Exporter проверяет свой конфиг через `--config.check`.
Деплой завершается успешно после проверки целей, HTTPS-проб и поступления метрик.
При провале печатает `docker compose ps` и логи.

Откат на конкретную версию: указать в `.env` тег образа (`PORTFOLIO_TAG`, `BOOKREVIEWS_TAG`,
`FOODGRAM_TAG`, `LOADGEN_TAG`, `PVZ_TAG`) равным sha коммита и сделать `docker compose up -d`.

### Prometheus

Prometheus собирает метрики `pvz:9000`, `billing:9001`, самого себя и двух экспортёров каждые
30 секунд. На VPS он подключён к сетям `proxy` и `monitoring`. Интерфейс и API опубликованы
на `127.0.0.1:9090` сервера. Открыть интерфейс с компьютера можно через SSH-туннель.

```bash
ssh -N -L 127.0.0.1:19090:127.0.0.1:9090 deploy@<IP_сервера>
```

Пока туннель работает, откройте http://127.0.0.1:19090/.
Порт 19090 на компьютере позволяет одновременно использовать локальный Prometheus ПВЗ на 9090.

Настройки находятся в [deploy/prometheus/prometheus.yml](deploy/prometheus/prometheus.yml).
История хранится в volume `prometheus_data`: до 7 дней или до достижения целевого размера 512 МиБ,
в зависимости от того, что наступит раньше. Retention удаляет старые блоки; WAL, текущие данные
и компактация требуют дополнительного места. Это не жёсткая квота на размер volume.
История сохраняется при пересоздании контейнера и обычном деплое; в бэкап проекта не входит.

Лимит контейнера — 192 МиБ; автоматический лимит Go — 80% от него. Одновременно выполняются
не больше двух запросов, таймаут — 10 с, до 500 тысяч samples на запрос. Сбор ограничен
5000 samples с одной цели за опрос. После первого деплоя нужно проверить фактическое потребление:
на VPS под нагрузкой должно оставаться не менее 500 МиБ available RAM, без OOM и постоянной подкачки.

Конфигурация смонтирована каталогом, чтобы `rsync` мог заменять файлы. Перед запуском Compose
`monitoring-prepare.py` создаёт семь HTTPS-целей из серверного `DOMAIN` и начальный файл метрик
бэкапа. Генерируемые файлы находятся в `backups/`, который сохраняется при `rsync --delete`.
При ручном применении на сервере выполните следующие команды.

```bash
cd /opt/givemeanoffer
python3 monitoring-prepare.py
docker compose run --rm --no-deps blackbox-exporter --config.file=/etc/blackbox/blackbox.yml --config.check
docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose up -d --wait node-exporter blackbox-exporter prometheus
docker compose kill -s SIGHUP blackbox-exporter
docker compose kill -s SIGHUP prometheus
python3 prometheus-check.py
```

Проверка ждёт до 120 секунд. Prometheus должен быть готов, все 12 целей должны иметь `up=1`,
конфигурация должна успешно загрузиться, а метрики приложений, хоста и бэкапа должны поступать.
Для всех семи HTTPS-целей дополнительно проверяются `probe_success=1` и срок сертификата.
Изменения параметров контейнера в `compose.yaml` применяются обычным деплоем через `up -d`.

Примеры PromQL для приложений.

```promql
up{job=~"pvz|billing"}
sum(rate(pvz_http_request_duration_seconds_count[5m]))
histogram_quantile(0.99, sum by (le) (rate(pvz_http_request_duration_seconds_bucket[5m])))
pvz_outbox_pending
billing_consumer_lag
billing_dlq_size
```

Версия образа закреплена: [Prometheus 3.16.0](https://github.com/prometheus/prometheus/releases/tag/v3.16.0).
Параметры сверены с [документацией конфигурации](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
и [хранения](https://prometheus.io/docs/prometheus/latest/storage/). Локальная конфигурация `pvz-service` отдельная.

### Хост и HTTPS

Node Exporter получает `/proc`, `/sys` и корень VPS через read-only mounts. Включены коллекторы
CPU, meminfo, filesystem, loadavg, vmstat, diskstats и textfile. Корневой диск имеет метку
`mountpoint="/"`. Виртуальные mount points и каталоги Docker исключены из файловых систем.
Blackbox Exporter проверяет главную, редирект `www` с кодом 301, BookReviews `/ready`, список
рецептов, статус loadgen, health ПВЗ и billing. Остальные проверки требуют код 200.
Все пробы требуют HTTPS с проверкой цепочки сертификата и выполняются раз в минуту.
Редиректы не проходят автоматически, поэтому неожиданный переход на другой URL виден как ошибка.

Оба экспортёра доступны в отдельной сети `monitoring`. Blackbox использует публичные DNS-имена
и адрес VPS, поэтому проверяет также DNS, TLS и вход через Caddy. Интервал — 60 секунд,
таймаут пробы — 5 секунд. У каждого экспортёра лимит 64 МиБ и `GOMEMLIMIT=48MiB`.

```promql
100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))
node_memory_MemAvailable_bytes / 1024^2
node_filesystem_avail_bytes{mountpoint="/"} / 1024^3
probe_success{job="https"}
(probe_ssl_earliest_cert_expiry{job="https"} - time()) / 86400
```

Закреплены версии [Node Exporter 1.12.1](https://github.com/prometheus/node_exporter/releases/tag/v1.12.1)
и [Blackbox Exporter 0.29.1](https://github.com/prometheus/blackbox_exporter/releases/tag/v0.29.1).

### Метрики бэкапа

`backup.sh` держит `flock` на всё время работы. Повторный одновременный запуск завершается с кодом 1
и сохраняет метрики текущего запуска. `backup-metrics.py` атомарно заменяет `backups/metrics/backup.prom`.
Каталог бэкапов имеет права 0700, в Node Exporter смонтирован только подкаталог с числовыми метриками.

| Метрика с префиксом `givemeanoffer_backup_` | Значение |
|---|---|
| `last_attempt_timestamp_seconds` | начало последней попытки, Unix time |
| `last_success_timestamp_seconds` | завершение последней полностью успешной копии, Unix time |
| `last_run_success` | результат последнего завершённого запуска, 1 или 0 |
| `last_run_duration_seconds` | длительность последнего завершённого запуска |
| `in_progress` | запуск начался и ещё не сообщил о завершении |

Успех требует дампа, медиа, внешней копии restic, её ротации и наличия эталона Фудграма.
При ошибке сохраняется прежний `last_success_timestamp_seconds` и исходный код выхода бэкапа.
Обработчик завершения записывает неуспех и при SIGINT/SIGTERM. После SIGKILL или потери питания
`in_progress=1` остаётся до следующего запуска. Ошибка публикации метрик записывается в лог.

При первом деплое все значения равны нулю до первого наблюдаемого запуска. История из старых
логов не переносится. Успешный деплой требует наличия этих метрик, первый успешный бэкап
проверяется после штатного ночного запуска. Повторные деплои сохраняют результат.

```promql
givemeanoffer_backup_last_run_success
givemeanoffer_backup_in_progress
time() - givemeanoffer_backup_last_success_timestamp_seconds
node_textfile_scrape_error
```

Регрессионные тесты запускаются в Linux командой `python3 -m unittest discover -s tests -v`.
Они исполняют `backup.sh` с подставным Docker в отдельном временном каталоге.

### Бэкапы

Главное, что нельзя потерять, это книги в BookReviews: коллекция заполнена вручную.

- [backup.sh](deploy/backup.sh), cron каждую ночь в 03:30: дамп БД BookReviews и обложки в
  `backups/<дата>/` на сервере (хранятся последние 7), затем restic отправляет их в Yandex Object
  Storage. Туда же идёт эталон Фудграма. Хранение: 7 ежедневных, 4 недельных, 6 месячных снапшотов.
- restic шифрует данные на сервере; пароль и ключи бакета только в `.env` и в менеджере паролей.
- [restore-check.sh](deploy/restore-check.sh), раз в месяц: разворачивает последний снапшот во временном
  Postgres без сети и сравнивает число книг и обложек с рабочей базой. Рабочие сервисы не трогает.
- [foodgram-reset.sh](deploy/foodgram-reset.sh), cron в 04:00: возвращает БД и медиа Фудграма
  к эталону. `foodgram-reset.sh snapshot` снимает новый эталон из текущего состояния.
- [pvz-reset.sh](deploy/pvz-reset.sh), cron в 04:10: удаляет данные посетителей демо ПВЗ-сервиса
  и создаёт эталонный набор заново. Демо публичное, данные не ценные, в бэкап не входят.

### Калибровка формы нагрузки

`max_rps` в `targets.json` меряется на самом сервере, в тихое время и без деплоев во время замера:
на одном ядре любой посторонний процесс портит цифры.

```sh
cal_dir=$(mktemp -d /tmp/loadgen-cal.XXXXXX)
cp /opt/givemeanoffer/loadgen/targets.json "$cal_dir/"
chmod 777 "$cal_dir"
chmod 666 "$cal_dir/targets.json"
docker run --rm --network givemeanoffer_proxy --memory 384m -v "$cal_dir:/cal" \
  ghcr.io/hollowkaeden/loadgen-web:latest \
  calibrate -targets /cal/targets.json -domain givemeanoffer.ru -start 2
```

Результат переносится в [deploy/loadgen/targets.json](deploy/loadgen/targets.json) и коммитится.

5 ноября 2026, после добавления Kafka и billing, выполнена повторная калибровка:

| Цель | Прежний max_rps | Новый max_rps | p99 последней прошедшей ступени | Первая непройденная ступень | Потолок формы (50%) |
|---|---:|---:|---:|---:|---:|
| Главная | 363 | 247 | 8,1 мс | 309 RPS | 123 RPS |
| Список книг | 60 | 38 | 36,2 мс | 48 RPS | 19 RPS |
| Рецепты Фудграма | 7 | 9 | 299,9 мс | 12 RPS | 4 RPS |

Генератор работает на том же 1 vCPU и ходит через TLS и Caddy по внутренним алиасам.
Ступени по 10 с, пауза 5 с, рост в 1,25 раза; p99 ≤ 500 мс, ошибок < 1%, фактическая
скорость ≥ 90% заданной. Это последние прошедшие ступени, точная граница между ними не измерялась.
Первый замер книг остановился уже на начальных 10 RPS (p99 727,9 мс); после завершения
серии повтор с 2 RPS дошёл до 38 RPS. Причина первого выброса не установлена.
Оба результата и параметры сохранены в [полном выводе калибровки](docs/loadgen/2026-11-05.txt).
RPS в форме и сервисе округляется вниз: 50% от 9 — это 4, а не 5 запросов/с.
Если даже 1 RPS выше потолка доли, цель не показывается и запустить её нельзя.
ПВЗ в белый список не добавлен: его API требует авторизации.

В двух сериях available не опускалось ниже 768 МиБ, swap занимал не больше 144 МиБ из 2047.
Пики рабочего набора по выборкам каждые 2 с: Caddy 111,9 МиБ, Kafka 462,6, pvz 9,3, billing 22,8.
Проверка cgroup показала, что Caddy достигал лимита 128 МиБ без OOM; в Compose лимит поднят
до 192 МиБ, `GOMEMLIMIT=160MiB`. Лимиты pvz/billing/Kafka 128/64/512 МиБ сохранены.
Замеры сделаны до публикации новой карточки и изменения лимита Caddy: после CI и деплоя
нужно проверить ресурсы и контрольной калибровкой подтвердить главную с новым HTML.
