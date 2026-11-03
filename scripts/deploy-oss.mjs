import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { installerFiles, validateBuild } from './validate-build.mjs';

export function createDeploymentPlan(directory) {
  return validateBuild(directory)
    .sort((a, b) => {
      const phase = (file) => file === 'index.html' ? 2 : Number(file.endsWith('.html'));
      return phase(a) - phase(b) || a.localeCompare(b, 'en');
    })
    .map((key) => ({
      key,
      file: path.join(directory, key),
      cacheControl: installerFiles.includes(key) && key.endsWith('.sh') ? 'no-cache' : key.startsWith('_astro/')
        ? 'public,max-age=31536000,immutable'
        : 'public,max-age=300',
    }));
}

export async function uploadWebsite(client, plan, log = console.log) {
  // Finish every asset before exposing pages that reference it; homepage goes last.
  // Keep older assets so already-open pages and retained builds remain usable.
  for (const item of plan) {
    await client.put(item.key, item.file, {
      ...(item.key.endsWith('.html') ? { mime: 'text/html; charset=utf-8' } : {}),
      ...(installerFiles.includes(item.key) ? { mime: 'text/plain; charset=utf-8' } : {}),
      headers: { 'Cache-Control': item.cacheControl },
    });
    log(`Uploaded ${item.key}`);
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== '--dry-run')) throw new Error('Usage: npm run deploy [-- --dry-run]');
  const plan = createDeploymentPlan(path.resolve('dist'));
  if (args.includes('--dry-run')) {
    for (const item of plan) console.log(`${item.key}\t${item.cacheControl}`);
    console.log(`Validated ${plan.length} files; no network requests or uploads performed.`);
    return;
  }
  for (const name of ['OSS_BUCKET', 'OSS_REGION', 'ACCESS_KEYID', 'ACCESS_KEYSECRET']) {
    if (!process.env[name]?.trim()) throw new Error(`Required environment variable is missing: ${name}`);
  }
  const { default: OSS } = await import('ali-oss');
  const client = new OSS({
    bucket: process.env.OSS_BUCKET,
    region: `oss-${process.env.OSS_REGION}`,
    accessKeyId: process.env.ACCESS_KEYID,
    accessKeySecret: process.env.ACCESS_KEYSECRET,
    secure: true,
    authorizationV4: true,
  });
  await uploadWebsite(client, plan);
  console.log(`Published ${plan.length} files to oss://${process.env.OSS_BUCKET}/`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    // Do not dump SDK request objects: they may contain authorization headers.
    console.error(`Deployment failed: ${error.code ?? error.name}: ${error.message}`);
    process.exitCode = 1;
  });
}
