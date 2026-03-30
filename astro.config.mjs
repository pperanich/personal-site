// @ts-check

import alpinejs from "@astrojs/alpinejs";
import sitemap from "@astrojs/sitemap";
import { defineConfig } from "astro/config";

// https://astro.build/config
export default defineConfig({
	site: "https://prestonperanich.com",
	integrations: [alpinejs(), sitemap()],
});
