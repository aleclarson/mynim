import { spawn } from 'node:child_process';
import { constants } from 'node:os';

export async function runProcess(executable, args, options) {
  const child = spawn(executable, args, { stdio: 'inherit', ...options });
  const handlers = new Map();
  for (const signal of ['SIGINT', 'SIGTERM']) {
    const forward = () => child.kill(signal);
    handlers.set(signal, forward);
    process.on(signal, forward);
  }
  try {
    return await new Promise((resolve, reject) => {
      child.on('error', reject);
      child.on('close', (code, signal) => resolve(code ?? (128 + (constants.signals[signal] || 1))));
    });
  } finally {
    for (const [signal, handler] of handlers) process.off(signal, handler);
  }
}
