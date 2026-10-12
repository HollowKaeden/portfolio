import { getCollection, getEntry, type CollectionEntry } from 'astro:content';
import { DOMAIN } from 'astro:env/server';

export type Project = CollectionEntry<'projects'>['data'];
export type Demo = NonNullable<Project['demo']>;

export async function getSite() {
  const entry = await getEntry('site', 'site');
  if (!entry) throw new Error('site.yaml: нет разделов meta/profile');
  return entry.data;
}

// Порядок коллекций не гарантирован, поэтому сортируем по позиции в site.yaml.
export async function getProjects(): Promise<Project[]> {
  const entries = await getCollection('projects');
  return entries.map((e) => e.data).sort((a, b) => a.order - b.order);
}

export async function getAchievementsByYear() {
  const entries = await getCollection('achievements');
  const byYear = new Map<number, CollectionEntry<'achievements'>['data'][]>();
  for (const { data } of entries.sort((a, b) => a.data.order - b.data.order)) {
    byYear.set(data.year, [...(byYear.get(data.year) ?? []), data]);
  }
  return [...byYear.entries()].sort(([a], [b]) => b - a).map(([year, items]) => ({ year, items }));
}

export function demoUrl(demo: Demo): string | undefined {
  return demo.type === 'link' ? `https://${demo.subdomain}.${DOMAIN}/` : undefined;
}

export const projectPath = (slug: string) => `/projects/${slug}/`;

export const isExternal = (url: string) => /^https?:\/\//.test(url);
