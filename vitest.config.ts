import { defineConfig } from 'vitest/config';
import path from 'path';

// The Supabase edge functions are written for Deno (`npm:` specifiers, `.ts`
// import suffixes). These aliases let vitest run that exact source, untouched:
//   stripe, bcryptjs  -> the real packages (so signature checks and password
//                        hashing in tests are the real thing)
//   supabase-js       -> a stub; tests pass in an in-memory fake instead
//   qrcode            -> a stub; no image generation needed
export default defineConfig({
  resolve: {
    alias: [
      { find: /^npm:stripe@\d+$/, replacement: 'stripe' },
      { find: /^npm:bcryptjs@[\d.]+$/, replacement: 'bcryptjs' },
      { find: /^npm:@supabase\/supabase-js@\d+$/, replacement: path.resolve(__dirname, 'tests/edge/stubs/supabase-js.ts') },
      { find: /^npm:qrcode@[\d.]+$/, replacement: path.resolve(__dirname, 'tests/edge/stubs/qrcode.ts') },
      { find: '@', replacement: path.resolve(__dirname, 'src') },
    ],
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts', 'tests/edge/**/*.test.ts'],
    exclude: ['node_modules', 'dist', '.claude/**'],
    // src/lib/supabase.ts throws at import time without these.
    env: {
      VITE_SUPABASE_URL: 'http://localhost:54321',
      VITE_SUPABASE_ANON_KEY: 'test-anon-key',
    },
  },
});
