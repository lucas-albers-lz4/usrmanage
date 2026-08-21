// @ts-check
const { test, expect } = require('@playwright/test');
const {
	luciLogin,
	luciLogoutClear,
	openUserManagement,
	openDeviceHealth,
	uniqueUsername,
	sshDelUser,
	sshAddUser,
	sshSetLuciLogin,
	sshResetPolicyOpenWrt,
	sshSetPolicyPreset,
	fillAddUserForm,
	expectLuciLoginDenied,
	E2E_USER_PASSWORD,
} = require('./helpers');

test.describe('LuCI User Management', () => {
	/** @type {string[]} */
	const created = [];
	/** Keeper admin so last_admin never blocks cleanup of test users. */
	const keeper = 'ume2e_keeper';

	test.beforeAll(async () => {
		await sshDelUser(keeper);
		// keeper may still exist if last_admin blocked del — acceptable; it is already admin.
		await sshAddUser(keeper, 'admin').catch(() => {});
	});

	test.afterAll(async () => {
		// Keeper may be sole admin — leave on guest; lab reset / next beforeAll replaces.
		await sshDelUser(keeper);
	});

	test.afterEach(async () => {
		while (created.length) {
			const name = created.pop();
			if (name) await sshDelUser(name);
		}
		// Always restore OpenWrt policy — tour may Save Standard before failing.
		await sshResetPolicyOpenWrt();
	});

	test('login and open User Management without null litter', async ({ page }) => {
		await luciLogin(page);
		await openUserManagement(page);

		await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();
		await expect(page.getByTestId('usrmanage-add-user')).toBeVisible();
		await expect(page.locator('#view')).not.toContainText('null');
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	test('add readonly user succeeds without Request failed', async ({ page }) => {
		const username = uniqueUsername('pwflow');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await expect(page.getByRole('heading', { name: 'Add user' })).toBeVisible();
		await fillAddUserForm(page, { username, role: 'readonly' });

		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByText('Request failed')).toHaveCount(0);
		await expect(page.getByTestId(`usrmanage-row-${username}`)).toBeVisible({
			timeout: 30_000,
		});
	});

	test('add admin user', async ({ page }) => {
		const username = uniqueUsername('pwadmin');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'admin' });

		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });
		const row = page.getByTestId(`usrmanage-row-${username}`);
		await expect(row).toBeVisible({ timeout: 30_000 });
		await expect(row.getByRole('cell', { name: 'admin', exact: true })).toBeVisible();
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	test('set-role promote then demote', async ({ page }) => {
		const username = uniqueUsername('pwrole');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'readonly' });
		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });

		const row = () => page.getByTestId(`usrmanage-row-${username}`);
		await expect(row().getByRole('cell', { name: 'readonly', exact: true })).toBeVisible({
			timeout: 30_000,
		});

		await row().getByTestId('usrmanage-set-role').click();
		await page.getByTestId('usrmanage-set-role-select').selectOption('admin');
		await page.getByTestId('usrmanage-set-role-apply').click();
		await expect(row().getByRole('cell', { name: 'admin', exact: true })).toBeVisible({
			timeout: 30_000,
		});

		await row().getByTestId('usrmanage-set-role').click();
		await page.getByTestId('usrmanage-set-role-select').selectOption('readonly');
		await page.getByTestId('usrmanage-set-role-apply').click();
		await expect(row().getByRole('cell', { name: 'readonly', exact: true })).toBeVisible({
			timeout: 30_000,
		});
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	test('change password', async ({ page }) => {
		const username = uniqueUsername('pwpass');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'readonly' });
		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });

		const row = page.getByTestId(`usrmanage-row-${username}`);
		await expect(row).toBeVisible({ timeout: 30_000 });
		await row.getByTestId('usrmanage-passwd').click();
		await expect(page.getByRole('heading', { name: `Change password: ${username}` })).toBeVisible();
		await page.getByTestId('usrmanage-passwd-password').fill(E2E_USER_PASSWORD);
		await page.getByTestId('usrmanage-passwd-confirm').fill(E2E_USER_PASSWORD);
		const changeBtn = page.getByTestId('usrmanage-passwd-submit');
		await expect(changeBtn).toBeEnabled({ timeout: 10_000 });
		await changeBtn.click();
		await expect(page.getByText('Password updated')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	test('remove user cancel leaves row', async ({ page }) => {
		const username = uniqueUsername('pwkeep');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'readonly' });
		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });

		const row = page.getByTestId(`usrmanage-row-${username}`);
		await expect(row).toBeVisible({ timeout: 30_000 });
		await row.getByTestId('usrmanage-remove').click();
		await expect(page.getByRole('heading', { name: `Remove user: ${username}` })).toBeVisible();
		await page.getByRole('button', { name: 'Cancel', exact: true }).click();
		await expect(row).toBeVisible();
	});

	test('remove user confirms delete', async ({ page }) => {
		const username = uniqueUsername('pwdel');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'readonly' });
		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });

		const row = page.getByTestId(`usrmanage-row-${username}`);
		await expect(row).toBeVisible({ timeout: 30_000 });
		await row.getByTestId('usrmanage-remove').click();
		await page.getByTestId('usrmanage-remove-confirm').click();
		await expect(page.getByText('User removed')).toBeVisible({ timeout: 30_000 });
		await expect(row).toHaveCount(0);
		await expect(page.getByText('Request failed')).toHaveCount(0);
		// already deleted — avoid afterEach del noise
		created.pop();
	});

	test('mismatched password keeps Add disabled', async ({ page }) => {
		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await page.getByTestId('usrmanage-add-username').fill(uniqueUsername('pwmism'));
		await page.getByTestId('usrmanage-add-password').fill(E2E_USER_PASSWORD);
		await page.getByTestId('usrmanage-add-password-confirm').fill(`${E2E_USER_PASSWORD}x`);
		await expect(page.getByTestId('usrmanage-add-submit')).toBeDisabled();
		await page.getByRole('button', { name: 'Cancel', exact: true }).click();
	});

	test('enable and disable LuCI login from row actions', async ({ page }) => {
		const username = uniqueUsername('pwluci');
		created.push(username);

		await luciLogin(page);
		await openUserManagement(page);

		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'readonly' });
		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });

		const row = () => page.getByTestId(`usrmanage-row-${username}`);
		await expect(row()).toBeVisible({ timeout: 30_000 });

		await row().getByTestId('usrmanage-luci-enable').click();
		await page.getByTestId('usrmanage-luci-enable-confirm').click();
		await expect(row().getByTestId('usrmanage-luci-state')).toHaveText('On', {
			timeout: 30_000,
		});
		await expect(page.getByText('Request failed')).toHaveCount(0);

		await row().getByTestId('usrmanage-luci-disable').click();
		await page.getByTestId('usrmanage-luci-disable-confirm').click();
		await expect(row().getByTestId('usrmanage-luci-state')).toHaveText('Off', {
			timeout: 30_000,
		});
		await expect(row().getByTestId('usrmanage-luci-enable')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	test('product tour: add, set-role, passwd, policy save, delete', async ({ page }) => {
		const username = uniqueUsername('pwflow');
		created.push(username);
		const row = () => page.getByTestId(`usrmanage-row-${username}`);

		await luciLogin(page);
		await openUserManagement(page);

		// Add readonly
		await page.getByTestId('usrmanage-add-user').click();
		await fillAddUserForm(page, { username, role: 'readonly' });
		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });
		await expect(row()).toBeVisible({ timeout: 30_000 });
		await expect(row().getByRole('cell', { name: 'readonly', exact: true })).toBeVisible();

		// Set role → admin
		await row().getByTestId('usrmanage-set-role').click();
		await expect(page.getByRole('heading', { name: `Set role: ${username}` })).toBeVisible();
		await page.getByTestId('usrmanage-set-role-select').selectOption('admin');
		await page.getByTestId('usrmanage-set-role-apply').click();
		await expect(row().getByRole('cell', { name: 'admin', exact: true })).toBeVisible({
			timeout: 30_000,
		});
		await expect(page.getByText('Request failed')).toHaveCount(0);

		// Change password
		await row().getByTestId('usrmanage-passwd').click();
		await expect(page.getByRole('heading', { name: `Change password: ${username}` })).toBeVisible();
		await page.getByTestId('usrmanage-passwd-password').fill(E2E_USER_PASSWORD);
		await page.getByTestId('usrmanage-passwd-confirm').fill(E2E_USER_PASSWORD);
		const changeBtn = page.getByTestId('usrmanage-passwd-submit');
		await expect(changeBtn).toBeEnabled({ timeout: 10_000 });
		await changeBtn.click();
		await expect(page.getByText('Password updated')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByText('Request failed')).toHaveCount(0);

		// Policy: OpenWrt default → Standard → Save
		await page.getByTestId('usrmanage-configure-policy').click();
		await expect(page.getByTestId('usrmanage-policy-preset')).toBeVisible();
		await page.getByTestId('usrmanage-policy-preset').selectOption('standard');
		await page.getByTestId('usrmanage-policy-save').click();
		await expect(page.getByText('Password policy saved')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByText('Request failed')).toHaveCount(0);
		await expect(page.locator('#view').getByText('Password policy: Standard')).toBeVisible({
			timeout: 30_000,
		});

		// Delete user
		await row().getByTestId('usrmanage-remove').click();
		await expect(page.getByRole('heading', { name: `Remove user: ${username}` })).toBeVisible();
		await page.getByTestId('usrmanage-remove-confirm').click();
		await expect(page.getByText('User removed')).toBeVisible({ timeout: 30_000 });
		await expect(row()).toHaveCount(0);
		await expect(page.getByText('Request failed')).toHaveCount(0);
		created.pop();
	});
});

test.describe('Password policy presets', () => {
	/**
	 * Efficient preset matrix (not every custom toggle combo):
	 * OpenWrt (factory) → Standard → Strict → OpenWrt, plus Strict blocks weak password in Add UI.
	 */
	test.afterEach(async () => {
		await sshResetPolicyOpenWrt();
	});

	test('cycle OpenWrt → Standard → Strict → OpenWrt via Configure policy', async ({ page }) => {
		await luciLogin(page);
		await openUserManagement(page);

		const strip = () => page.locator('#view').getByText(/Password policy:/);

		await expect(strip()).toContainText('OpenWrt');

		for (const [preset, label] of [
			['standard', 'Standard'],
			['strict', 'Strict'],
			['openwrt', 'OpenWrt'],
		]) {
			await page.getByTestId('usrmanage-configure-policy').click();
			await expect(page.getByTestId('usrmanage-policy-preset')).toBeVisible();
			await page.getByTestId('usrmanage-policy-preset').selectOption(preset);
			await page.getByTestId('usrmanage-policy-save').click();
			// Notifications stack across saves — assert strip label, not toast uniqueness.
			await expect(strip()).toContainText(label, { timeout: 30_000 });
			await expect(page.getByText('Request failed')).toHaveCount(0);
		}
	});

	test('Strict preset: Add form requires special char before submit enables', async ({ page }) => {
		await sshSetPolicyPreset('strict');
		await luciLogin(page);
		await openUserManagement(page);
		await expect(page.locator('#view').getByText(/Password policy: Strict/)).toBeVisible({
			timeout: 30_000,
		});

		await page.getByTestId('usrmanage-add-user').click();
		await page.getByTestId('usrmanage-add-username').fill(uniqueUsername('pwstrict'));
		// Meets length/case/digit but missing special under Strict.
		await page.getByTestId('usrmanage-add-password').fill('StrictPass12');
		await page.getByTestId('usrmanage-add-password-confirm').fill('StrictPass12');
		await expect(page.getByTestId('usrmanage-add-submit')).toBeDisabled();
		await expect(page.getByTestId('usrmanage-pwcheck-require_special')).toHaveAttribute('data-ok', '0');
		await expect(page.getByText(/special character/i)).toBeVisible();

		await page.getByTestId('usrmanage-add-password').fill('StrictPass12!');
		await page.getByTestId('usrmanage-add-password-confirm').fill('StrictPass12!');
		await expect(page.getByTestId('usrmanage-pwcheck-require_special')).toHaveAttribute('data-ok', '1');
		await expect(page.getByTestId('usrmanage-add-submit')).toBeEnabled({ timeout: 10_000 });
		await page.getByRole('button', { name: 'Cancel', exact: true }).click();
	});
});

test.describe('LuCI login matrix (role × luci opt-in)', () => {
	/**
	 * Efficient 2×2 + one lifecycle cell (not every disable×role combo):
	 *
	 * | role     | LuCI on | expect                          |
	 * |----------|---------|---------------------------------|
	 * | readonly | yes     | login → Device health           |
	 * | admin    | yes     | login → User Management (app)   |
	 * | readonly | no      | cannot web-login                |
	 * | admin    | no      | cannot web-login                |
	 * | *        | disable | cannot web-login (readonly once)|
	 *
	 * Scope `full` stays qemu-smoke / host ACL tests — not duplicated here.
	 */
	/** @type {string[]} */
	const created = [];
	const keeper = 'ume2e_mxkeeper';

	test.beforeAll(async () => {
		await sshDelUser(keeper);
		// keeper may still exist if last_admin blocked del — acceptable; it is already admin.
		await sshAddUser(keeper, 'admin').catch(() => {});
	});

	test.afterAll(async () => {
		await sshDelUser(keeper);
	});

	test.afterEach(async () => {
		while (created.length) {
			const name = created.pop();
			if (name) await sshDelUser(name);
		}
	});

	test('readonly + LuCI on → Device health', async ({ page }) => {
		const username = uniqueUsername('mxro');
		created.push(username);

		await sshAddUser(username, 'readonly', { luci: true });
		await luciLogoutClear(page);
		await luciLogin(page, username, E2E_USER_PASSWORD);
		await openDeviceHealth(page);

		await expect(page.getByTestId('usrmanage-health-map')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByTestId('usrmanage-health-readonly-banner')).toBeVisible();
		await expect(page.getByTestId('usrmanage-add-user')).toHaveCount(0);
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	test('admin + LuCI on → User Management', async ({ page }) => {
		const username = uniqueUsername('mxad');
		created.push(username);

		await sshAddUser(username, 'admin', { luci: true });
		await luciLogoutClear(page);
		await luciLogin(page, username, E2E_USER_PASSWORD);
		await openUserManagement(page);

		await expect(page.getByTestId('usrmanage-add-user')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByTestId('usrmanage-health-map')).toHaveCount(0);
		await expect(page.getByText('Request failed')).toHaveCount(0);
	});

	for (const role of /** @type {const} */ (['readonly', 'admin'])) {
		test(`${role} + LuCI off (never enabled) → cannot login`, async ({ page }) => {
			const username = uniqueUsername(`mx${role === 'admin' ? 'an' : 'rn'}`);
			created.push(username);

			await sshAddUser(username, role, { luci: false });
			await expectLuciLoginDenied(page, username);
		});
	}

	test('LuCI disable after enable → cannot login (readonly)', async ({ page }) => {
		const username = uniqueUsername('mxoff');
		created.push(username);

		await sshAddUser(username, 'readonly', { luci: true });
		await sshSetLuciLogin(username, 'disable');
		await expectLuciLoginDenied(page, username);
	});

	// https://github.com/lucas-albers-lz4/usrmanage/issues/142 — un-skip when Log out lands.
	test.skip('readonly observer has a Log out control (#142)', async ({ page }) => {
		const username = uniqueUsername('pwout');
		created.push(username);

		await sshAddUser(username, 'readonly', { luci: true });
		await luciLogoutClear(page);
		await luciLogin(page, username, E2E_USER_PASSWORD);
		await openDeviceHealth(page);

		const logout = page.getByRole('link', { name: /log\s*out/i })
			.or(page.getByRole('button', { name: /log\s*out/i }))
			.or(page.getByTestId('usrmanage-health-logout'));
		await expect(logout).toBeVisible({ timeout: 10_000 });
		await logout.click();
		await expect(page.getByRole('button', { name: 'Log in' })).toBeVisible({ timeout: 30_000 });
	});
});
