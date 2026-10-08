import { cloudflare } from "@cloudflare/vite-plugin";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react(), cloudflare()],
  build: {
    rollupOptions: {
      // The intro film is its own page at /intro/.
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        intro: resolve(import.meta.dirname, "intro/index.html"),
      },
    },
  },
});
