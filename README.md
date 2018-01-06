# Personal Site

A personal site and blog built with the [AHA Stack](https://ahastack.dev/) — Astro, htmx, and Alpine.js.

## Stack

- **[Astro](https://astro.build/)** — static site generation, file-based routing, content collections
- **[htmx](https://htmx.org/)** — HTML-over-the-wire server interactions
- **[Alpine.js](https://alpinejs.dev/)** — lightweight client-side interactivity

## Getting Started

```sh
bun install
bun run dev
```

## Project Structure

```
src/
├── content/
│   └── blog/          # Markdown blog posts
├── content.config.ts  # Content collection schema
├── components/        # Reusable components
├── layouts/
│   └── BaseLayout.astro
└── pages/
    ├── index.astro    # Home
    ├── about.astro    # About
    └── blog/
        ├── index.astro  # Blog listing
        └── [id].astro   # Blog post
```

## Commands

| Command          | Action                       |
| :--------------- | :--------------------------- |
| `bun install`    | Install dependencies         |
| `bun run dev`    | Start dev server             |
| `bun run build`  | Build for production         |
| `bun run preview`| Preview production build     |

## Adding a Blog Post

Create a new `.md` file in `src/content/blog/`:

```md
---
title: 'Post Title'
description: 'A short description.'
pubDate: 2026-03-18
tags: ['example']
---

Post content here.
```
