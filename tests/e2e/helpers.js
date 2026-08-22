// @ts-check
'use strict';

const { execFile, spawn } = require('node:child_process');
const { randomInt } = require('node:crypto');
const { promisify } = require('node:util');
const { expect } = require('@playwright/test');

const execFileAsync = promisify(execFile);

const LUCI_USER = process.env.USRMANAGE_LUCI_USER || 'root';
const LUCI_PASSWORD = process.env.USRMANAGE_LUCI_PASSWORD ?? '';
const OPENWRT_HOST = process.env.OPENWRT_HOST || '127.0.0.1';
const OPENWRT_SSH_PORT = process.env.OPENWRT_SSH_PORT || '2222';

/** Lab password for managed users created by e2e (never logged). */
const E2E_USER_PASSWORD = process.env.USRMANAGE_E2E_PASSWORD || 'LabPassE2E1!';

/**
 * @param {string[]} remoteCmd
 * @param {{ input?: string, timeout?: number }} [opts]
 * @returns {Promise<{ stdout: string, stderr: string }>}
 */
function sshExec(remoteCmd, opts = {}) {
	const sshArgs = [
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=10',
		'-p', OPENWRT_SSH_PORT,
		`root@${OPENWRT_HOST}`,
		...remoteCmd,
	];
	const timeout = opts.timeout ?? 30_000;

	if (opts.input == null) {
		return execFileAsync('ssh', sshArgs, { timeout, maxBuffer: 1024 * 1024 });
	}

	// Password (or other secrets) only on stdin — never argv.
	return new Promise((resolve, reject) => {
		const child = spawn('ssh', sshArgs, { stdio: ['pipe', 'pipe', 'pipe'] });
		/** @type {Buffer[]} */
		const out = [];
		/** @type {Buffer[]} */
		const err = [];
		const timer = setTimeout(() => {
			child.kill('SIGKILL');
			reject(new Error('ssh timed out'));
		}, timeout);
		child.stdout.on('data', (c) => out.push(c));
		child.stderr.on('data', (c) => err.push(c));
		child.on('error', (e) => {
			clearTimeout(timer);
			reject(e);
		});
		child.on('close', (code) => {
			clearTimeout(timer);
			const stdout = Buffer.concat(out).toString();
			const stderr = Buffer.concat(err).toString();
			if (code === 0) resolve({ stdout, stderr });
			else reject(Object.assign(new Error(`ssh exit ${code}`), { stdout, stderr, code }));
		});
		child.stdin.end(opts.input);
	});
}

/**
 * Establish a LuCI session (form POST — same as qemu HTTP smoke).
 * @param {import('@playwright/test').Page} page
 * @param {string} [username]
 * @param {string} [password]
 */
async function luciLogin(page, username = LUCI_USER, password = LUCI_PASSWORD) {
	const resp = await page.request.post('/cgi-bin/luci', {
		form: {
			luci_username: username,
			luci_password: password,
		},
		maxRedirects: 5,
	});
	if (!resp.ok() && resp.status() !== 302 && resp.status() !== 303) {
		throw new Error(`LuCI login HTTP ${resp.status()}`);
	}

	await page.goto('/cgi-bin/luci/', { waitUntil: 'domcontentloaded' });
	const loginBtn = page.getByRole('button', { name: 'Log in' });
	if (await loginBtn.isVisible().catch(() => false)) {
		// Cookie session missing — fall back to UI login.
		await page.getByRole('textbox', { name: 'Username' }).fill(username);
		await page.getByRole('textbox', { name: 'Password' }).fill(password);
		await loginBtn.click();
		await loginBtn.waitFor({ state: 'hidden', timeout: 30_000 });
	}
}

/**
 * Clear cookies so the next login is a different principal.
 * @param {import('@playwright/test').Page} page
 */
async function luciLogoutClear(page) {
	await page.context().clearCookies();
}

/**
 * @param {import('@playwright/test').Page} page
 */
async function openUserManagement(page) {
	await page.goto('/cgi-bin/luci/admin/system/usrmanage', {
		waitUntil: 'domcontentloaded',
	});
	await page.getByRole('heading', { name: 'User Management' }).waitFor({
		state: 'visible',
		timeout: 60_000,
	});
}

/**
 * @param {import('@playwright/test').Page} page
 */
async function openDeviceHealth(page) {
	await page.goto('/cgi-bin/luci/admin/system/usrmanage-health', {
		waitUntil: 'domcontentloaded',
	});
	await page.getByRole('heading', { name: 'Device health' }).waitFor({
		state: 'visible',
		timeout: 60_000,
	});
}

/**
 * Navigate to a LuCI admin path and fail if an RPC Access denied banner appears.
 * @param {import('@playwright/test').Page} page
 * @param {string} adminPath e.g. admin/status/routes
 * @param {{ heading?: RegExp|string, timeout?: number }} [opts]
 */
async function openLuciAdminView(page, adminPath, opts = {}) {
	const timeout = opts.timeout ?? 30_000;
	const path = adminPath.replace(/^\/+/, '');
	await page.goto(`/cgi-bin/luci/${path}`, { waitUntil: 'domcontentloaded' });
	if (opts.heading) {
		await page.getByRole('heading', { name: opts.heading }).waitFor({
			state: 'visible',
			timeout,
		});
	}
	// Stock LuCI paints the shell first, then fires ubus; wait past first paint
	// so a late Access denied cannot slip past an instant zero-count assert.
	await page.waitForTimeout(2_000);
	await expect(page.getByText(/RPCError|Access denied|Access Denied|-32002/i)).toHaveCount(0, {
		timeout: 15_000,
	});
}

/**
 * Unique managed username for a run (OpenWrt username rules: [a-z_][a-z0-9_-]*).
 * @param {string} [prefix]
 */
function uniqueUsername(prefix = 'pwflow') {
	const stamp = Date.now().toString(36).slice(-6);
	const rand = randomInt(0, 36).toString(36);
	return `${prefix}_${stamp}${rand}`.slice(0, 31);
}

/**
 * Best-effort guest cleanup. Passwords are never passed.
 * @param {string} username
 */
async function sshDelUser(username) {
	if (!/^[a-z_][a-z0-9_-]{0,30}$/.test(username)) {
		throw new Error('refusing unsafe username for SSH cleanup');
	}
	try {
		await sshExec([`usrmanage del ${username} 2>/dev/null || true`]);
	} catch {
		/* lab may be down after test failure; ignore */
	}
}

/**
 * Create a managed user via CLI (--password-fd; password only on stdin).
 * @param {string} username
 * @param {'readonly'|'admin'} role
 * @param {{ luci?: boolean, password?: string }} [opts]
 */
async function sshAddUser(username, role, opts = {}) {
	if (!/^[a-z_][a-z0-9_-]{0,30}$/.test(username)) {
		throw new Error('refusing unsafe username for SSH add');
	}
	if (role !== 'readonly' && role !== 'admin') {
		throw new Error('invalid role');
	}
	const password = opts.password ?? E2E_USER_PASSWORD;
	const luci = opts.luci ? ' --luci-login' : '';
	await sshExec(
		[`usrmanage add ${username} --role ${role}${luci} --password-fd 0`],
		{ input: `${password}\n` },
	);
}

/**
 * @param {string} username
 * @param {'enable'|'disable'|'reset'} action
 */
async function sshSetLuciLogin(username, action) {
	if (!/^[a-z_][a-z0-9_-]{0,30}$/.test(username)) {
		throw new Error('refusing unsafe username for set-luci-login');
	}
	if (action !== 'enable' && action !== 'disable' && action !== 'reset') {
		throw new Error('invalid luci login action');
	}
	await sshExec([`usrmanage set-luci-login ${username} --${action}`]);
}

/** Best-effort restore OpenWrt password policy on the guest. */
async function sshResetPolicyOpenWrt() {
	try {
		await sshExec(['usrmanage set-policy --preset openwrt']);
	} catch {
		/* ignore */
	}
}

/**
 * @param {'openwrt'|'standard'|'strict'} preset
 */
async function sshSetPolicyPreset(preset) {
	if (preset !== 'openwrt' && preset !== 'standard' && preset !== 'strict') {
		throw new Error('invalid policy preset');
	}
	await sshExec([`usrmanage set-policy --preset ${preset}`]);
}

/**
 * Fill Add-user modal and submit (caller opens the modal).
 * @param {import('@playwright/test').Page} page
 * @param {{ username: string, role?: 'readonly'|'admin', password?: string, luci?: boolean }} opts
 */
async function fillAddUserForm(page, opts) {
	const password = opts.password ?? E2E_USER_PASSWORD;
	await page.getByTestId('usrmanage-add-username').fill(opts.username);
	await page.getByTestId('usrmanage-add-role').selectOption(opts.role ?? 'readonly');
	if (opts.luci) {
		await page.getByTestId('usrmanage-add-luci-login').check();
	}
	await page.getByTestId('usrmanage-add-password').fill(password);
	await page.getByTestId('usrmanage-add-password-confirm').fill(password);
	const addBtn = page.getByTestId('usrmanage-add-submit');
	await addBtn.waitFor({ state: 'visible' });
	await expect(addBtn).toBeEnabled({ timeout: 10_000 });
	await addBtn.click();
}

/**
 * Assert username/password cannot establish a LuCI admin session.
 * @param {import('@playwright/test').Page} page
 * @param {string} username
 * @param {string} [password]
 */
async function expectLuciLoginDenied(page, username, password = E2E_USER_PASSWORD) {
	await luciLogoutClear(page);
	await page.goto('/cgi-bin/luci/', { waitUntil: 'domcontentloaded' });
	const loginBtn = page.getByRole('button', { name: 'Log in' });
	await expect(loginBtn).toBeVisible({ timeout: 30_000 });
	await page.getByRole('textbox', { name: 'Username' }).fill(username);
	await page.getByRole('textbox', { name: 'Password' }).fill(password);
	await loginBtn.click();
	// Stay on the login form — no session cookie / admin chrome.
	await expect(page.getByRole('button', { name: 'Log in' })).toBeVisible({ timeout: 15_000 });
	// Confirm no sysauth cookie was issued (login truly denied).
	const cookies = await page.context().cookies();
	const hasSysauth = cookies.some((c) => c.name === 'sysauth' || c.name === 'sysauth_https');
	expect(hasSysauth, 'sysauth cookie must not be set after a denied login').toBe(false);
	await page.goto('/cgi-bin/luci/admin/system/usrmanage', {
		waitUntil: 'domcontentloaded',
	});
	await expect(page.getByTestId('usrmanage-add-user')).toHaveCount(0);
	await page.goto('/cgi-bin/luci/admin/system/usrmanage-health', {
		waitUntil: 'domcontentloaded',
	});
	await expect(page.getByTestId('usrmanage-health-map')).toHaveCount(0);
}

module.exports = {
	luciLogin,
	luciLogoutClear,
	openUserManagement,
	openDeviceHealth,
	openLuciAdminView,
	uniqueUsername,
	sshDelUser,
	sshAddUser,
	sshSetLuciLogin,
	sshResetPolicyOpenWrt,
	sshSetPolicyPreset,
	fillAddUserForm,
	expectLuciLoginDenied,
	E2E_USER_PASSWORD,
	LUCI_USER,
};
