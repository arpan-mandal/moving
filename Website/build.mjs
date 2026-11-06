import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const args = process.argv.slice(2);
const preview = args.length === 1 && args[0] === '--preview';
if (args.length && !preview) throw new Error('Usage: node build.mjs [--preview]');

const release = JSON.parse(await readFile(join(root, 'release.json'), 'utf8'));
const { version, build, status, download } = release;
if (!/^\d+\.\d+\.\d+$/.test(version) || !Number.isSafeInteger(build) || build <= 0) {
  throw new Error('Enter a valid version and build number in release.json.');
}
if (status !== 'pending' && status !== 'published') {
  throw new Error('Release status must be pending or published.');
}

let artifact;
if (preview || status === 'published') {
  const filename = `Moving-${version}-universal.dmg`;
  if (download.filename !== filename) throw new Error(`Expected installer filename ${filename}.`);

  const folder = join(root, preview ? 'installers' : 'release-assets');
  const payload = await readFile(join(folder, filename));
  const digest = createHash('sha256').update(payload).digest('hex');
  let expected = download.sha256;
  if (preview) {
    const sidecar = await readFile(join(folder, `${filename}.sha256`), 'utf8');
    const [localDigest, localFilename] = sidecar.trim().split(/\s+/);
    if (localFilename !== filename) throw new Error('The local checksum names a different installer.');
    expected = localDigest;
  }
  if (digest !== expected) throw new Error(`SHA-256 mismatch for ${filename}.`);
  artifact = { filename, payload, digest };
}

let downloadMarkup = '<strong class="pending">Public download pending</strong><p>The installer is awaiting Developer ID signing and Apple notarization.</p>';
let checksumMarkup = '';
if (artifact) {
  const { filename, payload, digest } = artifact;
  const size = (payload.byteLength / (1024 * 1024)).toFixed(1);
  const label = preview ? 'Download test build' : 'Download for Mac';
  const info = preview
    ? 'Ad-hoc signed for local testing. The test build may be blocked by Gatekeeper.'
    : 'Universal installer for Apple silicon and Intel.';
  downloadMarkup = `<a class="primary" href="./downloads/${filename}" download>↓ ${label}</a>
              <p>v${version} · ${size} MiB · ${info}</p>`;
  checksumMarkup = `<details class="checksum"><summary>Installer SHA-256</summary>
              <p><code>${digest}</code><br><a href="./downloads/${filename}.sha256" download>Download checksum file</a></p></details>`;
}

const output = join(root, preview ? 'preview' : 'dist');
const source = join(root, 'src');
const staging = await mkdtemp(join(root, '.site-build-'));
try {
  await cp(source, staging, { recursive: true });
  const index = join(staging, 'index.html');
  const html = (await readFile(index, 'utf8'))
    .replaceAll('{{VERSION}}', version)
    .replaceAll('{{BUILD}}', String(build))
    .replace('<!-- release-download -->', downloadMarkup)
    .replace('<!-- release-checksum -->', checksumMarkup);
  await writeFile(index, html);
  if (artifact) {
    const downloads = join(staging, 'downloads');
    await mkdir(downloads);
    await writeFile(join(downloads, artifact.filename), artifact.payload);
    await writeFile(join(downloads, `${artifact.filename}.sha256`), `${artifact.digest}  ${artifact.filename}\n`);
  }
  await rm(output, { recursive: true, force: true });
  await rename(staging, output);
} finally {
  await rm(staging, { recursive: true, force: true });
}
console.log(`Built ${output}${preview ? ' (local installer preview)' : ''}`);
