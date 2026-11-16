const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const webDir = path.resolve(__dirname, '..');
const repoRoot = path.resolve(webDir, '..');
const deployScriptPath = path.join(webDir, 'bin', 'deploy');
const wranglerConfigPath = path.join(webDir, 'wrangler.json');
const packageJsonPath = path.join(webDir, 'package.json');
const jenkinsfilePath = path.join(repoRoot, 'Jenkinsfile.deploy');
const releasingPath = path.join(repoRoot, 'RELEASING.md');

test('Jenkinsfile.deploy defines a manual mac-mini pipeline wrapping web/bin/deploy', () => {
    const jenkinsfile = fs.readFileSync(jenkinsfilePath, 'utf8');

    assert.match(jenkinsfile, /agent\s*\{\s*label\s+'mac-mini'\s*\}/);
    assert.match(jenkinsfile, /disableConcurrentBuilds\(\)/);
    assert.match(jenkinsfile, /timeout\(time:\s*\d+,\s*unit:\s*'MINUTES'\)/);
    assert.doesNotMatch(jenkinsfile, /^\s*triggers\s*\{/m);

    assert.match(jenkinsfile, /name:\s*'REF'[\s\S]*?defaultValue:\s*'main'/);
    assert.match(jenkinsfile, /name:\s*'SKIP_BUILD'[\s\S]*?defaultValue:\s*false/);

    assert.match(jenkinsfile, /CLOUDFLARE_API_TOKEN\s*=\s*credentials\('cloudflare-api-token'\)/);
    assert.match(jenkinsfile, /CLOUDFLARE_ACCOUNT_ID\s*=\s*credentials\('cloudflare-account-id'\)/);

    assert.match(jenkinsfile, /dir\('web'\)\s*\{[\s\S]*?sh\s+'npm ci'/);
    assert.match(jenkinsfile, /node --test test\/server\.test\.js/);
    assert.match(jenkinsfile, /def flags = params\.SKIP_BUILD \? '--skip-build' : ''/);
    assert.match(jenkinsfile, /sh "bin\/deploy \$\{flags\}"\.trim\(\)/);

    const shBlocks = [...jenkinsfile.matchAll(/sh\s+'''([\s\S]*?)'''/g)].map((m) => m[1]);
    assert.ok(shBlocks.length >= 2, 'Expected inline shell blocks in Jenkinsfile.deploy');
    for (const [index, block] of shBlocks.entries()) {
        const check = spawnSync('bash', ['-n'], { input: block, encoding: 'utf8' });
        assert.equal(check.status, 0, `Jenkinsfile.deploy sh block #${index + 1} failed bash -n: ${check.stderr}`);
    }
});

test('web/wrangler.json, web/package.json, and RELEASING.md stay aligned with web/bin/deploy', () => {
    const wranglerConfig = JSON.parse(fs.readFileSync(wranglerConfigPath, 'utf8'));
    const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
    const deployScript = fs.readFileSync(deployScriptPath, 'utf8');
    const releasing = fs.readFileSync(releasingPath, 'utf8');

    assert.equal(wranglerConfig.name, 'herdcats');
    assert.equal(wranglerConfig.pages_build_output_dir, 'out');
    assert.equal(wranglerConfig.account_id, undefined);
    assert.equal(pkg.scripts.build, 'next build');

    assert.match(deployScript, /pages deploy out --project-name=herdcats --branch=main/);
    assert.match(releasing, /## Website deployment \(Cloudflare Pages\)/);
    assert.match(releasing, /`Jenkinsfile\.deploy`/);
    assert.match(releasing, /`cloudflare-api-token`/);
    assert.match(releasing, /`cloudflare-account-id`/);
    assert.match(releasing, /`enchantinglabs-jenkins`/);
    assert.match(releasing, /`REF`/);
    assert.match(releasing, /`SKIP_BUILD`/);
    // Existing iOS / TestFlight release documentation remains intact
    assert.match(releasing, /## Guided iOS \/ App Store Connect deployment/);
    assert.match(releasing, /\.\/ios\/bin\/deploy prepare/);
    assert.match(releasing, /\.\/ios\/bin\/deploy publish/);
});

test('web/bin/deploy enforces options, build/skip-build guards, Wrangler deploy, and smoke check', () => {
    const syntax = spawnSync('bash', ['-n', deployScriptPath], { encoding: 'utf8' });
    assert.equal(syntax.status, 0, syntax.stderr);

    const help = spawnSync('bash', [deployScriptPath, '--help'], { encoding: 'utf8' });
    assert.equal(help.status, 0, help.stderr);
    assert.match(help.stdout, /Usage: web\/bin\/deploy \[--skip-build\]/);

    const badOpt = spawnSync('bash', [deployScriptPath, '--unknown-flag'], { encoding: 'utf8' });
    assert.notEqual(badOpt.status, 0);
    assert.match(badOpt.stderr, /Unknown option: --unknown-flag/);

    const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'herdcats-web-deploy-test-'));
    try {
        const fakeWeb = path.join(tempRoot, 'web');
        const fakeBin = path.join(fakeWeb, 'bin');
        const fakeToolBin = path.join(tempRoot, 'tools');
        const wranglerDir = path.join(fakeWeb, 'node_modules', 'wrangler', 'bin');
        const nextBinDir = path.join(fakeWeb, 'node_modules', '.bin');
        const callLog = path.join(tempRoot, 'calls.log');

        fs.mkdirSync(fakeBin, { recursive: true });
        fs.mkdirSync(fakeToolBin, { recursive: true });
        fs.mkdirSync(wranglerDir, { recursive: true });
        fs.mkdirSync(nextBinDir, { recursive: true });

        fs.copyFileSync(deployScriptPath, path.join(fakeBin, 'deploy'));
        fs.chmodSync(path.join(fakeBin, 'deploy'), 0o755);
        fs.writeFileSync(path.join(wranglerDir, 'wrangler.js'), '// stub wrangler\n');
        fs.writeFileSync(path.join(nextBinDir, 'next'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

        fs.writeFileSync(
            path.join(fakeToolBin, 'node'),
            `#!/usr/bin/env bash\nprintf 'node %s\\n' "$*" >> "${callLog}"\n`,
            { mode: 0o755 }
        );
        fs.writeFileSync(
            path.join(fakeToolBin, 'npm'),
            `#!/usr/bin/env bash\nprintf 'npm %s\\n' "$*" >> "${callLog}"\nif [[ "\${1:-}" == "run" && "\${2:-}" == "build" && "\${FAKE_BUILD_CREATE_OUT:-1}" == "1" ]]; then\n  mkdir -p out\n  printf '<!DOCTYPE html><title>Herdcats</title>' > out/index.html\nfi\n`,
            { mode: 0o755 }
        );
        fs.writeFileSync(
            path.join(fakeToolBin, 'curl'),
            `#!/usr/bin/env bash\nprintf 'curl %s\\n' "$*" >> "${callLog}"\nif [[ "\${FAKE_SMOKE_FAIL:-0}" == "1" ]]; then\n  exit 22\nfi\n`,
            { mode: 0o755 }
        );

        const baseEnv = {
            ...process.env,
            PATH: `${fakeToolBin}:${process.env.PATH}`,
            DEPLOY_URL: 'https://herdcats.dev',
            SMOKE_RETRY_DELAY: '0',
        };

        // 1. --skip-build fails closed when out/index.html is missing
        const skipMissing = spawnSync('bash', [path.join(fakeBin, 'deploy'), '--skip-build'], {
            cwd: fakeWeb,
            env: baseEnv,
            encoding: 'utf8',
        });
        assert.notEqual(skipMissing.status, 0);
        assert.match(skipMissing.stderr, /missing static export at web\/out\/index\.html/);

        // 2. Full build + deploy + smoke check succeeds
        fs.rmSync(callLog, { force: true });
        const fullRun = spawnSync('bash', [path.join(fakeBin, 'deploy')], {
            cwd: fakeWeb,
            env: baseEnv,
            encoding: 'utf8',
        });
        assert.equal(fullRun.status, 0, fullRun.stderr);
        const fullCalls = fs.readFileSync(callLog, 'utf8').trim().split('\n');
        assert.deepEqual(fullCalls, [
            'node node_modules/wrangler/bin/wrangler.js whoami',
            'npm run build',
            'node node_modules/wrangler/bin/wrangler.js pages deploy out --project-name=herdcats --branch=main',
            'curl -fsSL -o /dev/null --max-time 15 https://herdcats.dev',
        ]);

        // 3. --skip-build reuses existing out/index.html without running npm run build
        fs.rmSync(callLog, { force: true });
        const skipRun = spawnSync('bash', [path.join(fakeBin, 'deploy'), '--skip-build'], {
            cwd: fakeWeb,
            env: baseEnv,
            encoding: 'utf8',
        });
        assert.equal(skipRun.status, 0, skipRun.stderr);
        const skipCalls = fs.readFileSync(callLog, 'utf8').trim().split('\n');
        assert.deepEqual(skipCalls, [
            'node node_modules/wrangler/bin/wrangler.js whoami',
            'node node_modules/wrangler/bin/wrangler.js pages deploy out --project-name=herdcats --branch=main',
            'curl -fsSL -o /dev/null --max-time 15 https://herdcats.dev',
        ]);

        // 4. Smoke-check failure fails closed after 3 attempts
        fs.rmSync(callLog, { force: true });
        const smokeFail = spawnSync('bash', [path.join(fakeBin, 'deploy'), '--skip-build'], {
            cwd: fakeWeb,
            env: { ...baseEnv, FAKE_SMOKE_FAIL: '1' },
            encoding: 'utf8',
        });
        assert.notEqual(smokeFail.status, 0);
        assert.match(smokeFail.stderr, /Deploy succeeded but smoke check failed at https:\/\/herdcats\.dev/);
        const smokeFailCalls = fs.readFileSync(callLog, 'utf8').trim().split('\n');
        assert.equal(
            smokeFailCalls.filter((line) => line.startsWith('curl ')).length,
            3,
            'Expected 3 smoke-check attempts before failing'
        );
    } finally {
        fs.rmSync(tempRoot, { recursive: true, force: true });
    }
});
