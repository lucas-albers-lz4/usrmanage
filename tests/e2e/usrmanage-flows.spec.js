// @ts-check
const { test, expect } = require('@playwright/test');
const {
	luciLogin,
	openUserManagement,
	uniqueUsername,
	sshDelUser,
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
		await expect(page.getByRole('cell', { name: username, exact: true })).toBeVisible({
			timeout: 30_000,
		});
	});
});
