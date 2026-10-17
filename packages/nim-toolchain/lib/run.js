import { spawn } from 'node:child_process';
import { constants } from 'node:os';
import { getToolchain } from '../index.js';

export async function runTool(tool) {
  try {
    const toolchain = await getToolchain();
    const child = spawn(toolchain[tool], process.argv.slice(2), {
      stdio: 'inherit',
      env: toolchain.env,
    });
    const handlers = new Map();
    for (const signal of ['SIGINT', 'SIGTERM']) {
      const forward = () => child.kill(signal);
      handlers.set(signal, forward);
      process.on(signal, forward);
    }
    try {
      await new Promise((resolve, reject) => {
        child.on('error', reject);
        child.on('close', (code, signal) => {
          process.exitCode = code ?? (128 + (constants.signals[signal] || 1));
          resolve();
        });
      });
    } finally {
      for (const [signal, handler] of handlers) process.off(signal, handler);
    }
  } catch (error) {
    console.error(`nim-toolchain: ${error.message}`);
    process.exitCode = 1;
  }
}
