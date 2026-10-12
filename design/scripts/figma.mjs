// Выгрузка дизайна из Figma REST API.
// Токен и ключ файла читаются из givemeanoffer/.env.figma (вне репозитория) и никуда не выводятся.
//
//   node design/scripts/figma.mjs check            проверить доступ к файлу
//   node design/scripts/figma.mjs dump <out.json>  сохранить полное дерево файла
//   node design/scripts/figma.mjs export <ids> <dir> [scale] [format]  экспорт узлов (ids через запятую, png|svg)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const envPath = process.env.FIGMA_ENV ?? resolve(here, '../../../.env.figma');

function loadEnv(path) {
  const env = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$/);
    if (m) env[m[1]] = m[2].trim();
  }
  return env;
}

const { FIGMA_TOKEN, FIGMA_FILE_KEY } = loadEnv(envPath);
if (!FIGMA_TOKEN || !FIGMA_FILE_KEY) {
  console.error('FIGMA_TOKEN или FIGMA_FILE_KEY не заданы в', envPath);
  process.exit(1);
}

async function api(path) {
  const res = await fetch(`https://api.figma.com/v1${path}`, {
    headers: { 'X-Figma-Token': FIGMA_TOKEN },
  });
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    throw new Error(`Figma API ${res.status}: ${body}`);
  }
  return res.json();
}

const [cmd, ...args] = process.argv.slice(2);

if (cmd === 'check') {
  const f = await api(`/files/${FIGMA_FILE_KEY}?depth=2`);
  console.log(`OK: "${f.name}", изменён ${f.lastModified}, роль: ${f.role ?? '?'}`);
  for (const page of f.document.children) {
    console.log(`- страница "${page.name}"`);
    for (const n of page.children ?? []) {
      const b = n.absoluteBoundingBox;
      console.log(`    ${n.type} "${n.name}" id=${n.id}${b ? ` ${b.width}x${b.height}` : ''}`);
    }
  }
} else if (cmd === 'dump') {
  const f = await api(`/files/${FIGMA_FILE_KEY}?geometry=paths`);
  writeFileSync(args[0], JSON.stringify(f, null, 1));
  console.log('сохранено в', args[0]);
} else if (cmd === 'export') {
  const [ids, dir, scale = '1', format = 'png'] = args;
  mkdirSync(dir, { recursive: true });
  const r = await api(`/images/${FIGMA_FILE_KEY}?ids=${encodeURIComponent(ids)}&format=${format}&scale=${scale}`);
  for (const [id, url] of Object.entries(r.images)) {
    if (!url) { console.error('нет картинки для', id); continue; }
    const buf = Buffer.from(await (await fetch(url)).arrayBuffer());
    const file = join(dir, `${id.replace(/[:;]/g, '-')}.${format}`);
    writeFileSync(file, buf);
    console.log(id, '→', file);
  }
} else {
  console.error('команды: check | dump <out.json> | export <ids> <dir> [scale] [format]');
  process.exit(1);
}
