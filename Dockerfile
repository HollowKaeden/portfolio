# Сайт: статическая сборка Astro → образ Caddy со статикой.
# Caddyfile в образ не входит: он лежит в deploy/ и монтируется на сервере,
# чтобы правка роутинга не требовала пересборки образа.

FROM node:24-alpine AS build
WORKDIR /site
COPY site/package.json site/package-lock.json ./
RUN npm ci
COPY site/ ./
# Домен попадает в ссылки на демо при сборке.
ARG DOMAIN=givemeanoffer.ru
ENV DOMAIN=$DOMAIN
RUN npm run build

FROM caddy:2.11-alpine
COPY --from=build /site/dist /srv/site
