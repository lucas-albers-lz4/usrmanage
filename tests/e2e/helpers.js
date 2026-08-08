// @ts-check
'use strict';

const { execFile } = require('node:child_process');
const { randomInt } = require('node:crypto');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);

const LUCI_USER = process.env.USRMANAGE_LUCI_USER || 'root';
const LUCI_PASSWORD = process.env.USRMANAGE_LUCI_PASSWORD ?? '';
const OPENWRT_HOST = process.env.OPENWRT_HOST || '127.0.0.1';
const OPENWRT_SSH_PORT = process.env.OPENWRT_SSH_PORT || '2222';

/** Lab password for managed users created by e2e (never logged). */
const E2E_USER_PASSWORD = process.env.USRMANAGE_E2E_PASSWORD || 'LabPassE2E1!';

/**
 * Establish a LuCI session (form POST — same as qemu HTTP smoke).
 * @param {import('@playwright/test').Page} page
 */
async function luciLogin(page) {
	const resp = await page.request.post('/cgi-bin/luci', {
		form: {
			luci_username: LUCI_USER,
			luci_password: LUCI_PASSWORD,
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
		await page.getByRole('textbox', { name: 'Username' }).fill(LUCI_USER);
		await page.getByRole('textbox', { name: 'Password' }).fill(LUCI_PASSWORD);
		await loginBtn.click();
		await loginBtn.waitFor({ state: 'hidden', timeout: 30_000 });
	}
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
	const sshArgs = [
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=10',
		'-p', OPENWRT_SSH_PORT,
		`root@${OPENWRT_HOST}`,
		`usrmanage del ${username} 2>/dev/null || true`,
	];
	try {
		await execFileAsync('ssh', sshArgs, { timeout: 30_000 });
	} catch {
		/* lab may be down after test failure; ignore */
	}
}

/** Best-effort restore OpenWrt password policy on the guest. */
async function sshResetPolicyOpenWrt() {
	const sshArgs = [
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'ConnectTimeout=10',
		'-p', OPENWRT_SSH_PORT,
		`root@${OPENWRT_HOST}`,
		'usrmanage set-policy --preset openwrt',
	];
	try {
		await execFileAsync('ssh', sshArgs, { timeout: 30_000 });
	} catch {
		/* ignore */
	}
}

module.exports = {
	luciLogin,
	openUserManagement,
	uniqueUsername,
	sshDelUser,
	sshResetPolicyOpenWrt,
	E2E_USER_PASSWORD,
	LUCI_USER,
};
