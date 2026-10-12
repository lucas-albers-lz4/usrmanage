#!/usr/bin/env node
/**
 * Capture the documented LuCI User Management gallery as WebP (#15).
 * Requires a running QEMU lab and an empty managed-user registry; never boots QEMU.
 *
 *   npm run test:ui
 */
import { chromium } from '@playwright/test';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const base = (process.env.USRMANAGE_LUCI_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const luciUser = process.env.USRMANAGE_LUCI_USER || 'root';
const luciPassword = process.env.USRMANAGE_LUCI_PASSWORD || '';
const sshHost = process.env.OPENWRT_HOST || '127.0.0.1';
const sshPort = process.env.OPENWRT_SSH_PORT || '2222';
const fixtureUser = 'docuser';
const outputDir = path.resolve('docs/user/assets');
fs.mkdirSync(outputDir, { recursive: true });
// Stage beside the final assets so rename stays atomic even when /tmp is another filesystem.
const workDir = fs.mkdtempSync(path.join(outputDir, '.usrmanage-gallery-'));
const staged = [];
const webpEncoder = ['cwebp', 'ffmpeg'].find((tool) => {
	const probe = spawnSync(tool, tool === 'cwebp' ? ['-version'] : ['-hide_banner', '-version'], { encoding: 'utf8' });
	return !probe.error && probe.status === 0;
});
const allowedActors = new Set(['root', 'unknown', 'docuser', '-']);
let browser;
let page;
let fixtureMayExist = false;
let completed = false;
let failure;

function runSsh(command, input) {
	const result = spawnSync('ssh', [
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=10',
		'-p', sshPort,
		`root@${sshHost}`,
		command
	], {
		input,
		encoding: 'utf8',
		timeout: 60_000,
		maxBuffer: 1024 * 1024
	});
	if (result.error || result.status !== 0)
		throw new Error(`SSH command failed (${command}; status ${result.status ?? 'spawn error'})`);
	return result.stdout.trim();
}

function runSshOptional(command) {
	const result = spawnSync('ssh', [
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=10',
		'-p', sshPort,
		`root@${sshHost}`,
		command
	], { encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024 });
	if (result.error)
		throw new Error(`SSH command could not start (${command})`);
	return { status: result.status ?? 1, stdout: result.stdout.trim() };
}

function parseJson(raw, label) {
	try {
		return JSON.parse(raw);
	}
	catch {
		throw new Error(`${label} returned invalid JSON`);
	}
}

function managedUsers() {
	const reply = parseJson(runSsh('usrmanage list --json'), 'usrmanage list');
	if (!Array.isArray(reply.users))
		throw new Error('usrmanage list reply has no users array');
	return reply.users.map((user) => user.name).filter(Boolean);
}

function checkManagedUsers(allowed) {
	const users = managedUsers().sort();
	const expected = [...allowed].sort();
	if (JSON.stringify(users) !== JSON.stringify(expected))
		throw new Error(`managed-user allowlist mismatch (found: ${users.join(', ') || 'empty'}; expected: ${expected.join(', ') || 'empty'})`);
}

function checkAuditAllowlist() {
	const reply = parseJson(runSsh('usrmanage audit --json'), 'usrmanage audit');
	if (!Array.isArray(reply.events))
		throw new Error('usrmanage audit reply has no events array');
	for (const event of reply.events) {
		if (event.user && !new Set(['root', 'unknown', 'docuser', '-']).has(event.user))
			throw new Error(`audit contains an account name outside the gallery allowlist: ${event.user}`);
		if (event.actor && !allowedActors.has(event.actor))
			throw new Error(`audit contains an actor outside the gallery allowlist: ${event.actor}`);
	}
}

function checkOpenWrtPolicy() {
	const policy = parseJson(runSsh('usrmanage policy --json'), 'usrmanage policy');
	if (policy.preset !== 'openwrt' || policy.label !== 'OpenWrt')
		throw new Error('gallery requires the saved OpenWrt factory policy; refusing to change device policy');
}

function checkVisibleRows(allowed) {
	return page.locator('[data-testid^="usrmanage-row-"]').evaluateAll((rows, names) => {
		const shown = rows.map((row) => row.getAttribute('data-testid').replace('usrmanage-row-', '')).sort();
		return JSON.stringify(shown) === JSON.stringify([...names].sort());
	}, allowed);
}

async function checkNoBlockedNames() {
	const text = await page.locator('body').innerText();
	for (const blocked of ['umadmin', 'umsmoke', 'pwflow_', 'pwadmin_', 'ume2e_', 'm2410', 'm2512']) {
		if (text.includes(blocked))
			throw new Error(`refusing screenshot: blocked lab account marker ${blocked} is visible`);
	}
}

async function saveWebp(name, options = {}, target = page) {
	const png = await target.screenshot({ type: 'png', animations: 'disabled', ...options });
	const file = path.join(workDir, name);
	const command = webpEncoder === 'cwebp'
		? ['-quiet', '-q', '85', '-', '-o', file]
		: ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-vcodec', 'png', '-i', 'pipe:0', '-frames:v', '1', '-c:v', 'libwebp', '-quality', '85', '-f', 'webp', file];
	const result = spawnSync(webpEncoder, command, {
		input: png,
		encoding: 'buffer',
		timeout: 30_000
	});
	if (result.error || result.status !== 0 || !fs.existsSync(file))
		throw new Error(`cwebp failed while writing ${name}`);
	staged.push({ source: file, destination: path.join(outputDir, name) });
}

async function login() {
	const response = await page.request.post(`${base}/cgi-bin/luci`, {
		form: { luci_username: luciUser, luci_password: luciPassword },
		maxRedirects: 5
	});
	if (!response.ok() && response.status() !== 302 && response.status() !== 303)
		throw new Error(`LuCI login request failed with HTTP ${response.status()}`);
	await page.goto(`${base}/cgi-bin/luci/`, { waitUntil: 'domcontentloaded' });
	if (await page.locator('input[type="password"]').count())
		throw new Error('LuCI login did not succeed; refusing to capture the login form');
}

async function openUserManagement() {
	await page.goto(`${base}/cgi-bin/luci/admin/system/usrmanage`, { waitUntil: 'domcontentloaded' });
	await page.getByRole('heading', { name: 'User Management' }).waitFor({ state: 'visible', timeout: 30_000 });
	await page.getByTestId('usrmanage-build').waitFor({ state: 'visible', timeout: 30_000 });
}

async function removeFixture() {
	const current = runSshOptional('usrmanage show docuser --json');
	if (current.status === 0) {
		const reply = parseJson(current.stdout, 'usrmanage show docuser');
		if (reply.user && reply.user.managed) {
			const deleted = parseJson(runSsh('usrmanage del docuser --purge-home --json'), 'usrmanage del docuser');
			if (deleted.ok !== true)
				throw new Error('could not remove docuser gallery fixture');
		}
	}
}

try {
	if (!webpEncoder)
		throw new Error('cwebp or ffmpeg with libwebp is required to create WebP screenshots');

	checkManagedUsers([]);
	checkAuditAllowlist();
	checkOpenWrtPolicy();
	if (runSshOptional('id docuser >/dev/null 2>&1').status === 0)
		throw new Error('docuser already exists outside the managed-user registry; clean the lab before capture');

	browser = await chromium.launch();
	const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
	page = await context.newPage();
	await login();
	await openUserManagement();
	if (!(await checkVisibleRows([])))
		throw new Error('User Management table is not empty');
	if (!(await page.getByText('No managed users yet.', { exact: true }).isVisible()))
		throw new Error('empty managed-user confirmation is not visible');
	await checkNoBlockedNames();
	await saveWebp('usrmanage-empty.webp', { fullPage: true });

	await page.getByTestId('usrmanage-configure-policy').click();
	await page.getByTestId('usrmanage-policy-preset').waitFor({ state: 'visible' });
	await checkNoBlockedNames();
	await saveWebp('usrmanage-policy-editor.webp', { fullPage: true });
	await page.getByRole('button', { name: 'Cancel', exact: true }).click();

	await page.getByTestId('usrmanage-add-user').click();
	const dialog = page.getByRole('dialog');
	await dialog.waitFor({ state: 'visible' });
	if ((await dialog.locator('h4').innerText()) !== 'Add user')
		throw new Error('Add user dialog is not the active LuCI dialog');
	await page.waitForFunction(() => {
		const overlay = document.getElementById('modal_overlay');
		return overlay && document.body.classList.contains('modal-overlay-active')
			&& getComputedStyle(overlay).visibility === 'visible'
			&& getComputedStyle(overlay).opacity === '1';
	});
	const passwordInputs = dialog.locator('[data-testid="usrmanage-add-password"], [data-testid="usrmanage-add-password-confirm"]');
	if (await passwordInputs.count() !== 2)
		throw new Error('Add user dialog password fields are missing; refusing screenshot');
	const passwordValues = await passwordInputs.evaluateAll((inputs) => inputs.map((input) => input.value));
	if (passwordValues.some(Boolean))
		throw new Error('add dialog contains a non-empty password field; refusing screenshot');
	await saveWebp('usrmanage-add-dialog.webp', {}, dialog);
	await page.getByRole('button', { name: 'Cancel', exact: true }).click();

	const existing = runSshOptional('usrmanage show docuser --json');
	if (existing.status === 0)
		throw new Error('docuser became managed before fixture creation');
	fixtureMayExist = true;
	const demoPassword = `Doc${randomBytes(18).toString('base64url')}7!`;
	const addReply = parseJson(runSsh('usrmanage add docuser --role readonly --password-fd 0 --json', `${demoPassword}\n`), 'usrmanage add docuser');
	if (addReply.ok !== true)
		throw new Error('could not create the readonly gallery fixture');
	checkManagedUsers([fixtureUser]);
	checkAuditAllowlist();
	await openUserManagement();
	if (!(await checkVisibleRows([fixtureUser])))
		throw new Error('gallery fixture row is not the only visible managed user');
	await checkNoBlockedNames();
	await saveWebp('usrmanage-one-user.webp', { fullPage: true });

	await removeFixture();
	fixtureMayExist = false;
	checkManagedUsers([]);
	completed = true;
}
catch (error) {
	failure = error;
}
finally {
	if (fixtureMayExist) {
		try {
			await removeFixture();
			checkManagedUsers([]);
		}
		catch (cleanupError) {
			failure ||= cleanupError;
		}
	}
	if (browser)
		await browser.close().catch(() => {});
	if (!failure) {
		try {
			fs.mkdirSync(outputDir, { recursive: true });
			for (const image of staged)
				fs.renameSync(image.source, image.destination);
		}
		catch (writeError) {
			failure = writeError;
		}
	}
	if (failure || !completed)
		fs.rmSync(workDir, { recursive: true, force: true });
}

if (failure) {
	console.error(`Screenshot capture failed: ${failure.message}`);
	process.exitCode = 1;
}
else {
	console.log(`Wrote ${staged.length} WebP screenshots under ${outputDir}`);
}
