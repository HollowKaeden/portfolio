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
| Генератор нагрузки (Go): форма, которая нагружает этот же сервер | [givemeanoffer.ru/projects/http-loadgen/](https://givemeanoffer.ru/projects/http-loadgen/) | [http-loadgen](https://github.com/HollowKaeden/http-loadgen) |

## Как это устроено

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

BookReviews и Фудграм хранят данные в одном общем PostgreSQL, у каждого своя база и свой пользователь.

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
- **Реестры.** Маленькие образы (сайт, BookReviews, loadgen-web) лежат в ghcr, большие образы
  Фудграма в Docker Hub: с сервера в России ghcr отдаёт ~0.2 МБ/с, Docker Hub ~30 МБ/с.
- **Postgres общий** на оба проекта: две БД, два пользователя, `shared_buffers=128MB`,
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
  .env.example                переменные окружения (секреты только на сервере)
  bootstrap-server.sh         первичная настройка чистого VPS
  backup.sh                   ежедневный бэкап, локально и в Yandex Object Storage
  restore-check.sh            проверка, что бэкап восстанавливается
  foodgram-reset.sh           ежедневный сброс Фудграма к эталону
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
перечитывает Caddyfile, перезапускает `loadgen-web` (он читает `targets.json` при старте) и проверяет
главную, редирект с `www`, `/health` и `/ready` BookReviews, API Фудграма и `/loadgen/api/status`.
При провале печатает `docker compose ps` и логи.

Откат на конкретную версию: указать в `.env` тег образа (`PORTFOLIO_TAG`, `BOOKREVIEWS_TAG`,
`FOODGRAM_TAG`, `LOADGEN_TAG`) равным sha коммита и сделать `docker compose up -d`.

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

### Калибровка формы нагрузки

`max_rps` в `targets.json` меряется на самом сервере, в тихое время и без деплоев во время замера:
на одном ядре любой посторонний процесс портит цифры.

```sh
rm -rf /tmp/cal && mkdir /tmp/cal && cp /opt/givemeanoffer/loadgen/targets.json /tmp/cal/
chmod 777 /tmp/cal && chmod 666 /tmp/cal/targets.json
docker run --rm --network givemeanoffer_proxy --memory 384m -v /tmp/cal:/cal \
  ghcr.io/hollowkaeden/loadgen-web:latest \
  calibrate -targets /cal/targets.json -domain givemeanoffer.ru -start 2
```

Результат переносится в [deploy/loadgen/targets.json](deploy/loadgen/targets.json) и коммитится.
Сейчас: главная 363 rps, список книг 60, список рецептов Фудграма 7.
