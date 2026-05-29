import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    port: 9036,
    proxy: {
      '/api': 'http://localhost:9035',
      '/ws': {
        target: 'http://localhost:9035',
        ws: true,
      },
    },
  },
})
