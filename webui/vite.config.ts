import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Served by the SpokenFolio gateway at /ui/; in dev, API calls proxy to a
// locally running `spokenfolio serve --studio` (or the desktop app).
export default defineConfig({
  plugins: [react()],
  base: "/ui/",
  build: {
    outDir: "../Sources/SpokenFolioApp/WebUI/dist",
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    proxy: {
      "/api": "http://127.0.0.1:8787",
      "/v1": "http://127.0.0.1:8787",
      "/health": "http://127.0.0.1:8787",
    },
  },
});
