# Personal Site

A personal site and blog built with [Astro](https://astro.build/) and [Alpine.js](https://alpinejs.dev/).

## Stack

- **[Astro](https://astro.build/)** — static site generation, file-based routing, content collections
- **[Alpine.js](https://alpinejs.dev/)** — lightweight client-side interactivity
- **[Fuse.js](https://www.fusejs.io/)** — client-side fuzzy search

## Getting Started

```sh
bun install
bun run dev
```

## Project Structure

```
src/
├── content/
│   └── blog/            # Markdown blog posts
├── content.config.ts    # Content collection schema
├── layouts/
│   └── BaseLayout.astro
└── pages/
    ├── index.astro            # Home
    ├── about.astro            # About
    ├── apps.astro             # Apps
    ├── search-index.json.ts   # Search index endpoint
    ├── posts/
    │   ├── index.astro        # Blog listing
    │   └── [id].astro         # Blog post
    └── tags/
        ├── index.astro        # All tags
        └── [tag].astro        # Posts by tag
```

## Commands

| Command              | Action                       |
| :------------------- | :--------------------------- |
| `bun install`        | Install dependencies         |
| `bun run dev`        | Start dev server             |
| `bun run build`      | Build for production         |
| `bun run preview`    | Preview production build     |
| `bun run check`      | Lint and format check        |
| `bun run check:fix`  | Lint and format fix          |

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

## License

[MIT](LICENSE)
