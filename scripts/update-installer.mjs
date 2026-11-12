import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const repository = 'agentscope-ai/AgentTeams';
export const sha256 = (content) => createHash('sha256').update(content).digest('hex');

export function withTerminalInput(source) {
  if (!/^set -e(?:uo pipefail)?$/m.test(source)) throw new Error('Review installer shell setup before promotion.');
  // Parse the complete installer before running any prompt: stdin may contain the script itself.
  return source.replace(/^set -e(?:uo pipefail)?$/m, (setup) => `website_main() {\n${setup}`)
    + `
}

# Connect interactive pipe installs to the terminal; preserve file and automation input.
if [ -z "\${BASH_SOURCE[0]:-}" ] && [ "\${AGENTTEAMS_NON_INTERACTIVE:-0}" != "1" ]; then
    if ! { true </dev/tty; } 2>/dev/null; then
        echo "Interactive installation requires a terminal. For automation, set AGENTTEAMS_NON_INTERACTIVE=1 and the required configuration." >&2
        exit 1
    fi
    website_main "$@" </dev/tty
else
    website_main "$@"
fi
`;
}

export function checkRelease(release, version) {
  if (!/^v\d+\.\d+\.\d+$/.test(version) || release.tag_name !== version || release.draft || release.prerelease || !release.published_at) {
    throw new Error('Choose an explicitly published stable release tag, such as v1.2.5.');
  }
}

// These narrow patches are intentionally guarded: review changed upstream code
// before promoting a new installer; never silently apply a partial patch.
export function prepareInstaller(source, version, commit) {
  const replaceOnce = (before, after) => {
    if (source.split(before).length !== 2) throw new Error(`Upstream installer changed; review patch: ${before.slice(0, 85)}`);
    source = source.replace(before, after);
  };
  if (!source.startsWith('#!/bin/bash\n') || !source.includes(`AGENTTEAMS_KNOWN_STABLE_VERSION="${version}"`)) {
    throw new Error('Installer stable version does not match the selected release.');
  }
  replaceOnce('#!/bin/bash\n', `#!/bin/bash\n# AgentTeams website stable installer: ${version}\n# Source: https://github.com/${repository}/blob/${commit}/install/agentteams-install.sh\n# Modified: support interactive pipe installs and Podman platform checks; pin the default release and stop on missing versioned embedded images.\n# License: https://agentteams.cloud/agentteams-install.LICENSE\n`);
  replaceOnce('#   AGENTTEAMS_VERSION            Image tag            (default: latest)', `#   AGENTTEAMS_VERSION            Image tag            (website default: ${version})`);
  replaceOnce('AGENTTEAMS_AUTO_VERSION=0\n', `AGENTTEAMS_AUTO_VERSION=0\nif [ -z "\${AGENTTEAMS_VERSION}" ]; then\n    AGENTTEAMS_VERSION="\${AGENTTEAMS_KNOWN_STABLE_VERSION}"\n    AGENTTEAMS_AUTO_VERSION=1\nfi\n`);
  replaceOnce('step_version() {\n', `step_version() {\n    # Restore the website default when navigating back through the wizard.\n    if [ -z "\${AGENTTEAMS_VERSION}" ]; then\n        AGENTTEAMS_VERSION="\${AGENTTEAMS_KNOWN_STABLE_VERSION}"\n        AGENTTEAMS_AUTO_VERSION=1\n    fi\n`);
  replaceOnce('    fi\n\n    log "$(msg install.image.pulling_embedded "${_latest}")"', `        die "Pinned embedded image \${_versioned} is unavailable. Refusing fallback to latest."\n    fi\n\n    log "$(msg install.image.pulling_embedded "\${_latest}")"`);
  // v1.2.7 used Docker-only platform fields; Podman exposes them under Host.
  replaceOnce("    platform=$(${DOCKER_CMD} info --format '{{.OSType}}/{{.Architecture}}') || die \"Cannot determine the container engine platform.\"", "    platform=$(${DOCKER_CMD} info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null) ||\n        platform=$(${DOCKER_CMD} info --format '{{.Host.OS}}/{{.Host.Arch}}') ||\n        die \"Cannot determine the container engine platform.\"");
  return withTerminalInput(source);
}

export function withDashboardLocalDefault(source) {
  const defaults = [...source.matchAll(/\$\{AGENTTEAMS_LOCAL_ONLY:-([^}]+)\}/g)];
  if (!defaults.length || defaults.some((match) => !['0', '1'].includes(match[1]))) {
    throw new Error('Review Dashboard port binding before promotion.');
  }
  return source.replaceAll('${AGENTTEAMS_LOCAL_ONLY:-0}', '${AGENTTEAMS_LOCAL_ONLY:-1}');
}

export function prepareDashboardInstaller(source, version, commit) {
  const replaceOnce = (pattern, replacement) => {
    if ([...source.matchAll(pattern)].length !== 1) throw new Error(`Upstream Dashboard installer changed; review patch: ${pattern}`);
    source = source.replace(pattern, () => replacement);
  };
  replaceOnce(/^#!\/usr\/bin\/env bash\n/gm, `#!/usr/bin/env bash\n# AgentTeams website Dashboard installer: ${version}\n# Source: https://github.com/agentteams-group/agentteams-dashboard/blob/${commit}/install/agentteams-dashboard.sh\n# Modified: support interactive pipe installs; pin the release, bind locally by default, and stop on image pull failure.\n# License: https://agentteams.cloud/agentteams-dashboard.LICENSE\n`);
  replaceOnce(/^DEFAULT_DASHBOARD_VERSION="[^"]+"$/gm, `DEFAULT_DASHBOARD_VERSION="${version}"`);
  // Keep explicit LAN access opt-in consistent with the main AgentTeams installer.
  source = withDashboardLocalDefault(source);
  source = source.replace('pull latest image & recreate', 'refresh configured image & recreate')
    .replace('# ---------- pull or build image ----------', '# ---------- ensure released image ----------')
    .replace('# Pull latest image (force re-pull to get updates)', '# Refresh the image selected in the saved configuration')
    .replace('Pulling latest image ${AGENTTEAMS_DASHBOARD_IMAGE}...', 'Pulling configured image ${AGENTTEAMS_DASHBOARD_IMAGE}...');
  replaceOnce(/^ensure_image\(\) \{\n[\s\S]*?^\}/gm, `ensure_image() {
  local image="$1"
  if ! \${DOCKER_CMD} image inspect "\${image}" >/dev/null 2>&1; then
    info "Pulling image \${image}..."
    \${DOCKER_CMD} pull "\${image}" || {
      err "Cannot pull \${image}. Installation stopped; no local source build was attempted."
      exit 1
    }
  fi
}`);
  replaceOnce(/^  \$\{DOCKER_CMD\} pull "\$\{AGENTTEAMS_DASHBOARD_IMAGE\}" \|\| \{\n[\s\S]*?^  \}/gm, `  \${DOCKER_CMD} pull "\${AGENTTEAMS_DASHBOARD_IMAGE}" || {
    err "Cannot pull \${AGENTTEAMS_DASHBOARD_IMAGE}. Update stopped; existing container was preserved."
    exit 1
  }`);
  return withTerminalInput(source);
}

async function download(url, json = false) {
  const result = json
    ? spawnSync('gh', ['api', new URL(url).pathname.slice(1)], { encoding: 'utf8', timeout: 30_000 })
    : spawnSync('curl', ['--fail', '--silent', '--show-error', '--location', '--max-time', '30', url], { encoding: 'utf8', timeout: 35_000, maxBuffer: 2 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`Download failed: ${url}: ${result.stderr || result.error}`);
  return json ? JSON.parse(result.stdout) : result.stdout;
}

async function main() {
  const args = process.argv.slice(2);
  const dashboard = args[0] === '--dashboard';
  if (dashboard) args.shift();
  const [version, ...extra] = args;
  if (!version || extra.length || !/^v\d+\.\d+\.\d+$/.test(version)) throw new Error('Usage: npm run installer:update[:dashboard] -- vX.Y.Z');
  const selectedRepository = dashboard ? 'agentteams-group/agentteams-dashboard' : repository;
  const filename = dashboard ? 'agentteams-dashboard' : 'agentteams-install';
  const metadataFile = dashboard ? 'dashboard-installer-release.json' : 'installer-release.json';
  const release = await download(`https://api.github.com/repos/${selectedRepository}/releases/tags/${version}`, true);
  checkRelease(release, version);
  const { sha: commit } = await download(`https://api.github.com/repos/${selectedRepository}/commits/${version}`, true);
  if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error('Invalid release commit.');
  const sourceURL = `https://raw.githubusercontent.com/${selectedRepository}/${commit}/install/${filename}.sh`;
  const [upstream, license] = await Promise.all([
    download(sourceURL), download(`https://raw.githubusercontent.com/${selectedRepository}/${commit}/LICENSE`),
  ]);
  const installer = (dashboard ? prepareDashboardInstaller : prepareInstaller)(upstream, version, commit);
  const syntax = spawnSync('bash', ['-n'], { input: installer, encoding: 'utf8' });
  if (syntax.status !== 0) throw new Error(`Installer syntax check failed: ${syntax.stderr || syntax.error}`);
  const metadata = {
    version, repository: selectedRepository, commit, publishedAt: release.published_at, sourceURL,
    upstreamSha256: sha256(upstream), sha256: sha256(installer), licenseSha256: sha256(license),
  };
  fs.writeFileSync(path.join(root, `public/${filename}.sh`), installer);
  fs.writeFileSync(path.join(root, `public/${filename}.LICENSE`), license);
  fs.writeFileSync(path.join(root, metadataFile), `${JSON.stringify(metadata, null, 2)}\n`);
  console.log(`Prepared ${filename} ${version} from ${commit}. Review the installer diff, run checks, and publish the website to promote it.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
