import { readFileSync } from 'node:fs';
import { step } from './machine.mjs';

try {
  process.stdout.write(JSON.stringify(step(JSON.parse(readFileSync(0, 'utf8')))) + '\n');
} catch (error) {
  process.stderr.write(`ci-agent: ${error.message}\n`);
  process.exitCode = 1;
}
