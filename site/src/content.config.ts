import { defineCollection } from 'astro:content';
import { file } from 'astro/loaders';
import { z } from 'astro/zod';
import { parse } from 'yaml';

// Весь контент лежит в одном файле site.yaml. Загрузчик file() ждёт список записей с id,
// поэтому из одного файла делаются несколько коллекций, каждая берёт свой раздел.
const SOURCE = 'src/content/site.yaml';

const section = (pick: (doc: any) => Record<string, unknown>[]) =>
  file(SOURCE, { parser: (text) => pick(parse(text)) });

const link = z.object({
  label: z.string(),
  url: z.string(),
});

const site = defineCollection({
  loader: section((doc) => [{ id: 'site', meta: doc.meta, profile: doc.profile }]),
  schema: z.object({
    meta: z.object({
      title: z.string(),
      description: z.string(),
      image: z.string().startsWith('/').optional(),
      image_alt: z.string().optional(),
    }),
    profile: z.object({
      name: z.string(),
      location: z.string(),
      greeting: z.string(),
      links: z.array(link).min(1),
    }),
  }),
});

const projects = defineCollection({
  loader: section((doc) =>
    (doc.projects ?? []).map((p: any, order: number) => ({ id: p.slug, order, ...p })),
  ),
  schema: z.object({
    order: z.number(),
    slug: z.string().regex(/^[a-z0-9-]+$/),
    title: z.string(),
    summary: z.string(),
    description: z.string().optional(),
    stack: z.array(z.string()).default([]),
    repo: z.url().optional(),
    preview: z.string().optional(),
    demo: z
      .discriminatedUnion('type', [
        z.object({ type: z.literal('link'), subdomain: z.string().regex(/^[a-z0-9-]+$/) }),
        z.object({ type: z.literal('loadgen-form') }),
      ])
      .optional(),
  }),
});

const achievements = defineCollection({
  loader: section((doc) =>
    (doc.achievements ?? []).map((a: any, order: number) => ({ id: String(order), order, ...a })),
  ),
  schema: z.object({
    order: z.number(),
    year: z.number().int(),
    title: z.string(),
    description: z.string().optional(),
  }),
});

export const collections = { site, projects, achievements };
