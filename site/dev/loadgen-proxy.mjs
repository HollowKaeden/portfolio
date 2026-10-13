// Только для `astro dev`. В проде /loadgen/api держит Caddy (handle_path срезает префикс),
// здесь то же делает этот плагин: шлёт запросы на локальный loadgen-web
// (`go run ./cmd/loadgen-web serve` в http-loadgen). Прокси Vite не подходит: Astro ставит
// свои middleware (проверку trailingSlash) в начало стека, и запрос до прокси не доходит.
import { request } from 'node:http';

const PREFIX = '/loadgen/api';
const UPSTREAM = { host: '127.0.0.1', port: 8080 };

/** @returns {import('vite').Plugin} */
export function loadgenDevProxy() {
  return {
    name: 'loadgen-dev-proxy',
    apply: 'serve',
    configureServer(server) {
      const proxy = (req, res) => {
        const upstream = request(
          { ...UPSTREAM, method: req.method, path: req.url, headers: req.headers },
          (up) => {
            res.writeHead(up.statusCode ?? 502, up.headers);
            up.pipe(res); // SSE идёт потоком, без буферизации
          },
        );
        upstream.on('error', () => {
          if (res.headersSent) return void res.destroy(); // обрыв посреди потока SSE
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: `loadgen-web не запущен на ${UPSTREAM.host}:${UPSTREAM.port}` }));
        });
        // Браузер ушёл: закрываем и запрос к loadgen-web, иначе он не узнает,
        // что зрителей больше нет, и не отменит прогон.
        res.on('close', () => upstream.destroy());
        req.pipe(upstream);
      };
      // Хук после остальных плагинов: встаём в начало стека позже Astro, то есть перед ним.
      // connect сам срезает route из req.url, как handle_path в Caddy.
      return () => {
        server.middlewares.stack.unshift({ route: PREFIX, handle: proxy });
      };
    },
  };
}
