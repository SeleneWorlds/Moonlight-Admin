import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

export default defineConfig({
  root: 'ui',
  base: './',
  publicDir: 'public',
  server: {
    cors: { origin: 'https://cef.seleneworlds.com' },
  },
  plugins: [
    vue(),
    {
      name: 'bundle-ui-entrypoint',
      apply: 'build',
      generateBundle() {
        this.emitFile({
          type: 'asset',
          fileName: 'index.html',
          source:
            '<!doctype html>\n<html lang="en">\n<head>\n  <meta charset="UTF-8">\n  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n  <title>Moonlight Admin</title>\n  <script type="module" src="./ui.js"></script>\n  <link rel="stylesheet" href="./ui.css">\n</head>\n<body>\n  <div id="moonlight-admin"></div>\n</body>\n</html>\n',
        });
      },
    },
  ],
  build: {
    outDir: '../client/ui/dist',
    emptyOutDir: true,
    assetsInlineLimit: Number.POSITIVE_INFINITY,
    rollupOptions: {
      input: 'ui/src/main.ts',
      preserveEntrySignatures: 'strict',
      output: {
        entryFileNames: 'ui.js',
        assetFileNames: 'ui.[ext]',
      },
    },
  },
});
