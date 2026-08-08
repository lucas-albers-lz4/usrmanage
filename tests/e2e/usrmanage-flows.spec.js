// @ts-check
const { test, expect } = require('@playwright/test');
const {
	luciLogin,
	openUserManagement,
	uniqueUsername,
	sshDelUser,
	sshResetPolicyOpenWrt,
	E2E_USER_PASSWORD,
} = require('./helpers');

test.describe('LuCI User Management', () => {
	/** @type {string[]} */
	const created = [];

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

		await page.getByTestId('usrmanage-add-username').fill(username);
		await page.getByTestId('usrmanage-add-role').selectOption('readonly');
		await page.getByTestId('usrmanage-add-password').fill(E2E_USER_PASSWORD);
		await page.getByTestId('usrmanage-add-password-confirm').fill(E2E_USER_PASSWORD);

		const addBtn = page.getByTestId('usrmanage-add-submit');
		await expect(addBtn).toBeEnabled({ timeout: 10_000 });
		await addBtn.click();

		await expect(page.getByText('User added')).toBeVisible({ timeout: 30_000 });
		await expect(page.getByText('Request failed')).toHaveCount(0);
		await expect(page.getByTestId(`usrmanage-row-${username}`)).toBeVisible({
			timeout: 30_000,
		});
	});

	test('product tour: add, set-role, passwd, policy save, delete', async ({ page }) => {
		const username = uniqueUsername('pwflow');
		created.push(username);
		const row = () => page.getByTestId(`usrmanage-row-${username}`);

		await luciLogin(page);
		await openUserManagement(page);

		// Add readonly
		await page.getByTestId('usrmanage-add-user').click();
		await page.getByTestId('usrmanage-add-username').fill(username);
		await page.getByTestId('usrmanage-add-role').selectOption('readonly');
		await page.getByTestId('usrmanage-add-password').fill(E2E_USER_PASSWORD);
		await page.getByTestId('usrmanage-add-password-confirm').fill(E2E_USER_PASSWORD);
		const addBtn = page.getByTestId('usrmanage-add-submit');
		await expect(addBtn).toBeEnabled({ timeout: 10_000 });
		await addBtn.click();
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
	});
});
