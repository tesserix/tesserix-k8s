import { expect, Page, test } from '@playwright/test';

const ADMIN_URL = 'https://admin.yahvismartfarm.com';

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

async function enterCredentials(page: Page): Promise<void> {
  await page.goto('/login', { waitUntil: 'networkidle', timeout: 30000 });

  const emailInput = page.locator(
    'input[type="email"], input[name="email"], input[placeholder*="email" i]',
  );
  await expect(emailInput).toBeVisible({ timeout: 10000 });
  await emailInput.fill(requiredEnv('E2E_ADMIN_EMAIL'));

  const continueButton = page
    .locator('button:has-text("Continue"), button:has-text("Next"), button[type="submit"]')
    .first();
  await continueButton.click();

  const tenantSelector = page
    .locator('[data-testid="tenant-select"], select, [role="listbox"]')
    .first();
  if (await tenantSelector.isVisible({ timeout: 3000 }).catch(() => false)) {
    await tenantSelector.click();
    await page.locator('[role="option"], option').first().click();
  }

  const passwordInput = page.locator('input[type="password"], input[name="password"]');
  await expect(passwordInput).toBeVisible({ timeout: 30000 });
  await passwordInput.fill(requiredEnv('E2E_ADMIN_PASSWORD'));
}

test.describe('Admin custom-domain login', () => {
  test.use({ baseURL: ADMIN_URL, ignoreHTTPSErrors: true });
  test.setTimeout(90000);

  test.beforeAll(() => {
    requiredEnv('E2E_ADMIN_EMAIL');
    requiredEnv('E2E_ADMIN_PASSWORD');
  });

  test('redirects away from the login page', async ({ page }) => {
    await enterCredentials(page);

    const navigation = page.waitForURL((url) => !url.pathname.includes('/login'), {
      timeout: 30000,
    });
    await page.locator('button:has-text("Sign In")').click();
    await navigation;

    expect(page.url()).toContain('admin.yahvismartfarm.com');
    expect(page.url()).not.toContain('/login');
  });

  test('does not redirect-loop when the tenant cookie is cleared', async ({ page }) => {
    await enterCredentials(page);
    await page.context().addCookies([
      {
        name: 'tenant-slug',
        value: '',
        domain: 'admin.yahvismartfarm.com',
        path: '/',
        expires: 0,
      },
    ]);

    const loginResponse = page.waitForResponse(
      (response) =>
        response.url().includes('/auth/direct/admin/login') && response.status() === 200,
    );
    const navigation = page.waitForURL((url) => !url.pathname.includes('/login'), {
      timeout: 30000,
    });
    await page.locator('button:has-text("Sign In")').click();
    await loginResponse;
    await page.context().clearCookies({ name: 'tenant-slug' });
    await navigation;

    expect(page.url()).toContain('admin.yahvismartfarm.com');
    expect(page.url()).not.toContain('/login');
    expect(page.url()).not.toContain('localhost');
  });
});
