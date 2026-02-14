import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 3000,
    proxy: {
      '/auth': process.env.VITE_API_URL || 'http://localhost:9091',
      '/tasks': process.env.VITE_API_URL || 'http://localhost:9091',
      '/usage': process.env.VITE_API_URL || 'http://localhost:9091',
    },
  },
})
