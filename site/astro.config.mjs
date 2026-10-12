// @ts-check
import { defineConfig, envField } from 'astro/config';

export default defineConfig({
  output: 'static',
  trailingSlash: 'always',
  env: {
    schema: {
      // Основной домен; поддомены демо строятся от него. Задаётся при сборке.
      DOMAIN: envField.string({ context: 'server', access: 'public', default: 'givemeanoffer.ru' }),
    },
  },
});
