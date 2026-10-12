#!/usr/bin/env node
/**
 * Capture WebP screenshots of LuCI User Management for docs (#15).
 * Requires a running QEMU lab with luci-app-usrmanage. Does not boot QEMU.
 *
 * Cleans the managed-user table first (allowlist only). Refuses to write
 * committed shots if stray smoke names are visible. Passwords never go on
 * argv and are never typed into screenshot fields.
 *
 *   USRMANAGE_LUCI_URL=http://127.0.0.1:8080 npm run test:ui
 */
import { chromium } from '@playwright/test';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'docs/user/assets');
const BASE = process.env.USRMANAGE_LUCI_URL || 'http://127.0.0.1:8080';
const LUCI_USER = process.env.USRMANAGE_LUCI_USER || 'root';
const LUCI_PASSWORD = process.env.USRMANAGE_LUCI_PASSWORD ?? '';
const HOST = process.env.OPENWRT_HOST || '127.0.0.1';
const SSH_PORT = process.env.OPENWRT_SSH_PORT || '2222';
const FIXTURE = 'docuser';
const USERNAME_RE = /^[a-z_][a-z0-9_-]{0,30}$/;
const STRAY_MARKERS = [
	'umadmin', 'umsmoke', 'pwflow_', 'pwadmin', 'pwrole', 'pwpass', 'pwkeep',
	'ume2e', 'mtx', 'm2410', 'm2512',
];
/** Lab-only fixture password (stdin / --password-fd; never logged or typed). */
const FIXTURE_PASSWORD = process.env.USRMANAGE_DOCUSER_PASSWORD || 'DocUserPass9';

fs.mkdirSync(OUT, { recursive: true });

function sshArgs() {
	return [
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'LogLevel=ERROR',
		'-o', 'ConnectTimeout=10',
		'-p', SSH_PORT,
		`root@${HOST}`,
	];
}

function guestAsh(script, opts = {}) {
	return spawnSync('ssh', [...sshArgs(), 'ash', '-s'], {
		encoding: 'utf8',
		input: script,
		timeout: opts.timeout ?? 60_000,
		maxBuffer: 1024 * 1024,
	});
}

function requireOk(r, label) {
	if (r.status === 0)
		return r;
	const detail = (r.stderr || r.stdout || r.error?.message || `exit ${r.status}`).trim();
	throw new Error(`${label}: ${detail}`);
}

/**
 * Remove managed users that are not in allowlist. last_admin is unwound
 * with a lab-only registry+UNIX delete so empty-table shots are possible.
 * Truncates the audit file so stray names cannot appear in the gallery.
 */
function guestResetTable(allowlist) {
	for (const n of allowlist) {
		if (!USERNAME_RE.test(n))
			throw new Error(`refusing unsafe allowlist name: ${n}`);
	}
	const resetPath = path.join(ROOT, 'scripts/lib/capture-guest-reset.sh');
	const script = fs.readFileSync(resetPath, 'utf8');
	const r = spawnSync('ssh', [...sshArgs(), 'ash', '-s', '--', ...allowlist], {
		encoding: 'utf8',
		input: script,
		timeout: 60_000,
		maxBuffer: 1024 * 1024,
	});
	requireOk(r, 'guest reset managed-user table');
}

function guestAddFixture() {
	if (!USERNAME_RE.test(FIXTURE))
		throw new Error('unsafe fixture username');
	const r = spawnSync('ssh', [
		...sshArgs(),
		`usrmanage add ${FIXTURE} --role readonly --password-fd 0`,
	], {
		encoding: 'utf8',
		input: `${FIXTURE_PASSWORD}\n`,
		timeout: 30_000,
	});
	requireOk(r, `usrmanage add ${FIXTURE}`);
}

function guestListNames() {
	const r = requireOk(guestAsh('usrmanage list\n'), 'usrmanage list');
	return (r.stdout || '')
		.split('\n')
		.map((line) => line.trim().split(/\s+/)[0])
		.filter(Boolean);
}

function assertAllowlist(allowlist) {
	const names = guestListNames();
	for (const n of names) {
		if (!allowlist.includes(n))
			throw new Error(`managed user ${n} is not on the capture allowlist`);
		for (const bad of STRAY_MARKERS) {
			if (n.includes(bad))
				throw new Error(`stray account marker "${bad}" in managed user ${n}`);
		}
	}
}

function assertPageClean(text, extraAllowed = []) {
	const allowed = new Set(extraAllowed);
	for (const bad of STRAY_MARKERS) {
		if (text.includes(bad))
			throw new Error(`Refusing capture: stray account marker "${bad}" visible. Clean the managed-user table first.`);
	}
	if (text.includes(FIXTURE) && !allowed.has(FIXTURE))
		throw new Error(`Refusing capture: fixture "${FIXTURE}" visible outside the documented shots.`);
}

async function luciLogin(page) {
	const resp = await page.request.post(`${BASE}/cgi-bin/luci`, {
		form: {
			luci_username: LUCI_USER,
			luci_password: LUCI_PASSWORD,
		},
		maxRedirects: 5,
	});
	if (!resp.ok() && resp.status() !== 302 && resp.status() !== 303)
		throw new Error(`LuCI login HTTP ${resp.status()}`);

	await page.goto(`${BASE}/cgi-bin/luci/`, { waitUntil: 'domcontentloaded' });
	const loginBtn = page.getByRole('button', { name: 'Log in' });
	if (await loginBtn.isVisible().catch(() => false)) {
		await page.getByRole('textbox', { name: 'Username' }).fill(LUCI_USER);
		await page.getByRole('textbox', { name: 'Password' }).fill(LUCI_PASSWORD);
		await loginBtn.click();
		await loginBtn.waitFor({ state: 'hidden', timeout: 30_000 });
	}
}

async function hideLabNags(page) {
	// Prepared images have an empty root password. That LuCI warning is a
	// lab artifact and must not appear in published user-doc shots.
	await page.evaluate(() => {
		document.querySelectorAll('.alert-message, .alert').forEach((el) => {
			const t = el.textContent || '';
			if (/no password set|root password|sysauth/i.test(t))
				el.remove();
		});
		const ver = document.getElementById('usrmanage-build');
		if (ver)
			ver.remove();
	});
}

async function openUserManagement(page) {
	await page.goto(`${BASE}/cgi-bin/luci/admin/system/usrmanage`, {
		waitUntil: 'domcontentloaded',
	});
	await page.getByRole('heading', { name: 'User Management' }).waitFor({
		state: 'visible',
		timeout: 60_000,
	});
	await page.getByTestId('usrmanage-build').waitFor({ state: 'visible', timeout: 30_000 });
	await hideLabNags(page);
}

function encodeWebp(pngPath, dest, quality) {
	const r = spawnSync('ffmpeg', [
		'-y', '-hide_banner', '-loglevel', 'error',
		'-i', pngPath, '-c:v', 'libwebp', '-quality', String(quality), dest,
	], { encoding: 'utf8' });
	requireOk(r, `webp encode ${path.basename(dest)} (ffmpeg libwebp; Playwright 1.60 writes png/jpeg only)`);
}

async function shot(page, name, opts = {}) {
	const dest = path.join(OUT, name);
	const tmp = path.join(os.tmpdir(), `usrmanage-shot-${process.pid}-${name}.png`);
	try {
		await page.screenshot({
			path: tmp,
			type: 'png',
			animations: 'disabled',
			caret: 'hide',
			fullPage: opts.fullPage ?? true,
			clip: opts.clip,
		});
			encodeWebp(tmp, dest, 85);
	} finally {
		fs.rmSync(tmp, { force: true });
	}
	console.log('wrote', path.relative(ROOT, dest));
}

async function shotElement(page, locator, name) {
	const box = await locator.boundingBox();
	if (!box)
		throw new Error(`no bounding box for ${name}`);
	await shot(page, name, {
		fullPage: false,
		clip: {
			x: Math.max(0, Math.floor(box.x)),
			y: Math.max(0, Math.floor(box.y)),
			width: Math.ceil(box.width),
			height: Math.ceil(box.height),
		},
	});
}

async function debugShot(page) {
	const dest = path.join(OUT, 'usrmanage-debug.webp');
	const tmp = path.join(os.tmpdir(), `usrmanage-debug-${process.pid}.png`);
	try {
		await page.screenshot({ path: tmp, type: 'png', fullPage: true });
		encodeWebp(tmp, dest, 70);
		console.error('wrote docs/user/assets/usrmanage-debug.webp (gitignored)');
	} catch {
		/* ignore */
	} finally {
		fs.rmSync(tmp, { force: true });
	}
}

let browser;
try {
	requireOk(guestAsh('command -v usrmanage >/dev/null && echo ok\n'), 'guest usrmanage');
	guestResetTable([]);
	assertAllowlist([]);

	browser = await chromium.launch({ headless: true });
	const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
	await luciLogin(page);
	await openUserManagement(page);
	await page.getByText('No managed users yet.').waitFor({ state: 'visible', timeout: 15_000 });
	assertPageClean(await page.locator('body').innerText(), []);
	await shot(page, 'usrmanage-empty.webp');

	await page.getByTestId('usrmanage-add-user').click();
	await page.getByRole('heading', { name: 'Add user' }).waitFor({ state: 'visible' });
	await page.getByTestId('usrmanage-add-username').fill(FIXTURE);
	// Leave password fields empty so no secret (or password-dots) is in the shot.
	const modal = page.locator('#modal_overlay .modal, .modal').last();
	await modal.waitFor({ state: 'visible' });
	await hideLabNags(page);
	assertPageClean(await page.locator('body').innerText(), [FIXTURE]);
	await shotElement(page, modal, 'usrmanage-add-dialog.webp');
	await page.getByRole('button', { name: 'Cancel' }).click();
	await page.getByRole('heading', { name: 'Add user' }).waitFor({ state: 'hidden' });

	await page.getByTestId('usrmanage-configure-policy').click();
	await page.getByTestId('usrmanage-policy-preset').waitFor({ state: 'visible' });
	assertPageClean(await page.locator('body').innerText(), []);
	const editor = page.getByTestId('usrmanage-policy-preset').locator('xpath=ancestor::div[contains(@class,"cbi-section")][1]');
	await shotElement(page, editor, 'usrmanage-policy-editor.webp');
	await page.getByTestId('usrmanage-configure-policy').click();

	guestAddFixture();
	assertAllowlist([FIXTURE]);
	await openUserManagement(page);
	await page.getByTestId(`usrmanage-row-${FIXTURE}`).waitFor({ state: 'visible', timeout: 30_000 });
	assertPageClean(await page.locator('body').innerText(), [FIXTURE]);
	await shot(page, 'usrmanage-one-user.webp');
} catch (err) {
	if (browser) {
		const pages = browser.contexts().flatMap((c) => c.pages());
		if (pages[0])
			await debugShot(pages[0]);
	}
	console.error(err);
	process.exitCode = 1;
} finally {
	try {
		guestResetTable([]);
	} catch (err) {
		console.error(err);
		process.exitCode = 1;
	}
	if (browser)
		await browser.close();
}
