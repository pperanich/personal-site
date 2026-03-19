// @ts-check

import alpinejs from "@astrojs/alpinejs";
import { defineConfig } from "astro/config";

// https://astro.build/config
export default defineConfig({
	integrations: [alpinejs()],
});
