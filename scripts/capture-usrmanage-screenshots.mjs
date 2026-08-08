#!/usr/bin/env node
/**
 * Capture WebP screenshots of LuCI User Management for docs (#15).
 * Requires a running QEMU lab with luci-app-usrmanage and a CLEAN managed-user
 * table (no umadmin / pwflow_* / smoke leftovers).
 *
 *   USRMANAGE_LUCI_URL=http://127.0.0.1:8080 node scripts/capture-usrmanage-screenshots.mjs
 */
import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

const base = process.env.USRMANAGE_LUCI_URL || 'http://127.0.0.1:8080';
const user = process.env.USRMANAGE_LUCI_USER || 'root';
const pass = process.env.USRMANAGE_LUCI_PASSWORD || '';
const outDir = path.resolve('docs/user/assets');
fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

async function luciLogin() {
	await page.goto(`${base}/cgi-bin/luci/`, { waitUntil: 'domcontentloaded' });
	const userSel = 'input[name="luci_username"], #login_username, input[type="text"]';
	const passSel = 'input[name="luci_password"], #login_password, input[type="password"]';
	if (await page.locator(passSel).count()) {
		await page.fill(userSel, user);
		await page.fill(passSel, pass);
		await page.click('button[type="submit"], input[type="submit"]');
		await page.waitForLoadState('networkidle');
	}
}

await luciLogin();
await page.goto(`${base}/cgi-bin/luci/admin/system/usrmanage`, { waitUntil: 'networkidle' });
// Refuse capture if known fixture names are visible
const body = await page.locator('body').innerText();
for (const bad of ['umadmin', 'pwflow_', 'mtx', 'm2410', 'm2512']) {
	if (body.includes(bad)) {
		console.error(`Refusing capture: stray account marker "${bad}" visible. Clean the managed-user table first.`);
		process.exit(2);
	}
}
await page.screenshot({ path: path.join(outDir, 'usrmanage-overview.webp'), type: 'webp', quality: 80, fullPage: true });
console.log('wrote docs/user/assets/usrmanage-overview.webp');
await browser.close();
