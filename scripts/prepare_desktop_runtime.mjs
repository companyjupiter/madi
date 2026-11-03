// Stage the original inference engines/assets for the experimental macOS app.
// No model download, user-data access or release publication is performed.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
export function prepareRuntime(target) {
  if (process.platform !== 'darwin' || process.arch !== 'arm64' || target !== 'aarch64-apple-darwin') {
    throw new Error(`The inference package currently requires native Apple Silicon: ${target}`);
  }
  const run = (program, args) => execFileSync(program, args, { cwd: root, env: { ...process.env, MADI_MACOS_DEPLOYMENT_TARGET: '14.0' }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], maxBuffer: 32 * 1024 * 1024 });
  if (run('zig', ['version']).trim() !== '0.14.1') throw new Error('The original ASR engine requires Zig 0.14.1 on PATH');
  const out = join(root, 'out/desktop-native');
  const resources = join(out, 'resources');
  // Only this script's generated staging directory; never package stale extras.
  rmSync(resources, { recursive: true, force: true });
  const digest = bytes => createHash('sha256').update(bytes).digest('hex');
  const records = [];
  const stage = (source, destination, expected) => {
    const metadata = lstatSync(source);
    if (!metadata.isFile()) throw new Error(`Expected a regular source file: ${source}`);
    const bytes = readFileSync(source);
    const sha256 = digest(bytes);
    if (expected && (bytes.length !== expected.bytes || sha256 !== expected.sha256)) {
      throw new Error(`Pinned runtime bytes differ: ${relative(root, source)}`);
    }
    mkdirSync(dirname(destination), { recursive: true });
    const temporary = `${destination}.tmp-${process.pid}`;
    writeFileSync(temporary, bytes, { mode: metadata.mode, flag: 'wx' });
    renameSync(temporary, destination);
    records.push({ source: relative(root, source), staged: relative(root, destination), bytes: bytes.length, sha256 });
  };
  const assets = JSON.parse(readFileSync(join(root, 'design/parity/runtime-assets-reference.json'), 'utf8'));
  // Verify all inputs before starting the build. Fetching the pinned archive is
  // an explicit developer/CI step, never an implicit prepare/build download.
  for (const asset of assets.files) {
    stage(join(root, 'engine/metal/assets', asset.name), join(resources, 'assets-small', asset.name), asset);
  }
  const manifest = JSON.parse(readFileSync(join(root, 'engine/prebuilt/MANIFEST.json'), 'utf8'));
  for (const name of ['translate-engine-2b', 'translate-engine-4b']) {
    const engine = manifest.engines.find(engine => engine.name === name);
    if (!engine || engine.arch !== 'arm64' || engine.minos !== '14.0') throw new Error(`Unsupported prebuilt engine metadata: ${name}`);
    stage(join(root, 'engine/prebuilt', name), join(out, `${name}-${target}`), { bytes: engine.size, sha256: engine.sha256 });
  }
  // Always rebuild from the current source; an existing engine/out executable
  // alone is not evidence that it matches this checkout or SDK.
  process.stdout.write(run('bash', ['apps/macos/scripts/build_engine.sh']));
  stage(join(root, 'engine/metal/out/transcribe'), join(out, `transcribe-${target}`));
  stage(join(root, 'engine/metal/whisper.metallib'), join(resources, 'whisper.metallib'));
  for (const name of ['LICENSE', 'NOTICE', 'THIRD_PARTY_LICENSES.md']) stage(join(root, name), join(resources, name));
  stage(join(root, 'engine/prebuilt/LICENSE.md'), join(resources, 'TRANSLATE_ENGINE_LICENSE.md'));
  const report = { schemaVersion: 1, target, records, runtimeAssetsArchiveSHA256: assets.archiveSHA256, productRelease: false };
  writeFileSync(join(out, 'runtime.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(`Staged ${records.length} inference runtime files and notices for ${target}`);
}
