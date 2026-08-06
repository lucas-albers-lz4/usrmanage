// @ts-check
const { defineConfig, devices } = require('@playwright/test');

const baseURL = process.env.USRMANAGE_LUCI_URL || 'http://127.0.0.1:8080';

/**
 * LuCI e2e against a prepared QEMU lab. Not run in PR CI.
 * @see docs/developer/testing.md
 */
module.exports = defineConfig({
	testDir: './tests/e2e',
	fullyParallel: false,
	forbidOnly: !!process.env.CI,
	retries: 0,
	workers: 1,
	reporter: [['list']],
	timeout: 120_000,
	expect: { timeout: 15_000 },
	use: {
		baseURL,
		// Never retain traces: LuCI mutator POSTs include password fields.
		trace: 'off',
		screenshot: 'only-on-failure',
		video: 'off',
		ignoreHTTPSErrors: true,
	},
	projects: [
		{
			name: 'chromium',
			use: { ...devices['Desktop Chrome'] },
		},
	],
});
