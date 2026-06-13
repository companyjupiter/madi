import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Scaffold config: base './' so the built dashboard can be served from any path
// (file://, a CDN subfolder, or embedded in the macOS app's WKWebView later).
export default defineConfig({
  plugins: [react()],
  base: './',
  server: { port: 5273, host: '127.0.0.1' },
})
