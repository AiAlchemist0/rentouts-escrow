import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [react()],
  // The ENS deployment addresses live one level up, in ens/deployments/sepolia.json.
  server: { fs: { allow: ['.', '../ens/deployments'] } },
  // viem (with the ENSIP-15 normalizer tables) + wagmi + React is ~650 kB; fine for a single-page demo.
  build: { chunkSizeWarningLimit: 800 },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
})
