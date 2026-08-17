import path from "path"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
  // Cloudflare Pages serves from the project root (popy.pages.dev/), so the
  // default base is correct. The README's relative image paths
  // ("assets/logo.png") resolve against it without rewriting.
  base: "/",
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
})
