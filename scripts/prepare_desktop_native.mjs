// Stage the Cargo-built native helper for Tauri's externalBin convention.
// Runs before Tauri dev/build (and explicitly in CI); no source files are edited.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const cargo = process.env.CARGO || 'cargo';
const rustc = process.env.RUSTC || 'rustc';
const run = (program, args) => execFileSync(program, args, { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'inherit'] });
const host = run(rustc, ['--print', 'host-tuple']).trim();
const target = process.env.TAURI_ENV_TARGET_TRIPLE || process.env.CARGO_BUILD_TARGET || host;
if (!target.endsWith('-apple-darwin')) {
  console.log(`Native audio decoder is not implemented for ${target}; no helper is staged.`);
  process.exit(0);
}
if (process.platform !== 'darwin' || !['aarch64-apple-darwin', 'x86_64-apple-darwin'].includes(target)) {
  throw new Error(`Native audio decoder requires a macOS build host and an explicit supported architecture: ${target}`);
}
const metadata = JSON.parse(run(cargo, ['metadata', '--locked', '--no-deps', '--format-version', '1']));
const packageId = metadata.packages.find(pkg => pkg.name === 'madi-platform')?.id;
if (!packageId) throw new Error('madi-platform package is missing');
const args = ['build', '--locked', '-p', 'madi-platform', '--message-format=json'];
if (target !== host || process.env.CARGO_BUILD_TARGET) args.push('--target', target);
const output = run(cargo, args);
const artifact = output.split('\n').filter(Boolean).map(line => JSON.parse(line))
  .find(message => message.reason === 'build-script-executed' && message.package_id === packageId);
if (!artifact) throw new Error('Cargo did not report the native decoder build output');
const helper = join(artifact.out_dir, 'madi-audio-decode');
const staged = join(root, 'out', 'desktop-native', `madi-audio-decode-${target}`);
mkdirSync(dirname(staged), { recursive: true });
const temporary = `${staged}.tmp-${process.pid}`;
copyFileSync(helper, temporary);
renameSync(temporary, staged);
const bytes = readFileSync(staged);
const report = {
  schemaVersion: 1, target, binary: relative(root, staged), bytes: bytes.length,
  sha256: createHash('sha256').update(bytes).digest('hex'),
  source: relative(root, helper), productRelease: false,
};
writeFileSync(`${staged}.json`, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
