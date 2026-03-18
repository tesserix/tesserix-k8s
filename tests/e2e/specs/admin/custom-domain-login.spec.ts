import { test, expect, Page } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const ADMIN_URL = 'https://admin.yahvismartfarm.com';
const EMAIL = 'samyak.rout@gmail.com';
const PASSWORD = 'Admin@123';

const screenshotDir = path.resolve(__dirname, '../../screenshots/custom-domain-login');

interface LogEntry {
  timestamp: string;
  type: string;
  text: string;
  url?: string;
}

interface NetworkEntry {
  method: string;
  url: string;
  status?: number;
  headers?: Record<string, string>;
  responseHeaders?: Record<string, string>;
}

function timestamp(): string {
  return new Date().toISOString();
}

test.describe('Admin Custom Domain Login - admin.yahvismartfarm.com', () => {
  let consoleLogs: LogEntry[] = [];
  let networkRequests: NetworkEntry[] = [];

  test.beforeAll(() => {
    fs.mkdirSync(screenshotDir, { recursive: true });
  });

  test.use({
    baseURL: ADMIN_URL,
    ignoreHTTPSErrors: true,
  });

  test.setTimeout(90000);

  test('login flow captures diagnostics and verifies redirect', async ({ page }) => {
    // Collect console logs
    page.on('console', (msg) => {
      consoleLogs.push({
        timestamp: timestamp(),
        type: msg.type(),
        text: msg.text(),
        url: page.url(),
      });
    });

    // Collect network requests/responses
    page.on('response', async (response) => {
      const req = response.request();
      const entry: NetworkEntry = {
        method: req.method(),
        url: req.url(),
        status: response.status(),
      };
      // Capture Set-Cookie headers from auth responses
      if (req.url().includes('/auth/')) {
        entry.responseHeaders = await response.allHeaders();
      }
      networkRequests.push(entry);
    });

    // Step 1: Navigate to login page
    console.log('--- Step 1: Navigate to login page ---');
    await page.goto('/login', { waitUntil: 'networkidle', timeout: 30000 });
    await page.screenshot({ path: path.join(screenshotDir, '01-login-page.png'), fullPage: true });
    console.log(`Current URL: ${page.url()}`);

    // Dump initial cookies
    const initialCookies = await page.context().cookies();
    console.log('Initial cookies:', JSON.stringify(initialCookies, null, 2));

    // Step 2: Enter email
    console.log('--- Step 2: Enter email ---');
    const emailInput = page.locator('input[type="email"], input[name="email"], input[placeholder*="email" i]');
    await expect(emailInput).toBeVisible({ timeout: 10000 });
    await emailInput.fill(EMAIL);
    await page.screenshot({ path: path.join(screenshotDir, '02-email-entered.png'), fullPage: true });

    // Step 3: Click Continue
    console.log('--- Step 3: Click Continue ---');
    const continueBtn = page.locator('button:has-text("Continue"), button:has-text("Next"), button[type="submit"]').first();
    await continueBtn.click();
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
    await page.screenshot({ path: path.join(screenshotDir, '03-after-continue.png'), fullPage: true });
    console.log(`URL after continue: ${page.url()}`);

    // Step 4: Check for tenant selection
    console.log('--- Step 4: Check for tenant selection ---');
    const tenantSelector = page.locator('[data-testid="tenant-select"], select, [role="listbox"]').first();
    const hasTenantSelect = await tenantSelector.isVisible({ timeout: 3000 }).catch(() => false);
    if (hasTenantSelect) {
      console.log('Tenant selection found, selecting first option');
      await tenantSelector.click();
      const option = page.locator('[role="option"], option').first();
      await option.click().catch(() => {});
      await page.screenshot({ path: path.join(screenshotDir, '04-tenant-selected.png'), fullPage: true });
    } else {
      console.log('No tenant selection found, proceeding');
    }

    // Step 5: Enter password (wait longer — the email verification step can take time)
    console.log('--- Step 5: Enter password ---');
    const passwordInput = page.locator('input[type="password"], input[name="password"]');
    await expect(passwordInput).toBeVisible({ timeout: 30000 });
    await passwordInput.fill(PASSWORD);
    await page.screenshot({ path: path.join(screenshotDir, '05-password-entered.png'), fullPage: true });

    // Step 6: Click Sign In
    console.log('--- Step 6: Click Sign In ---');
    const signInBtn = page.locator('button:has-text("Sign In")');
    await expect(signInBtn).toBeEnabled({ timeout: 10000 });

    // Listen for navigation after clicking sign in
    const navigationPromise = page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 30000 }).catch((e) => {
      console.log(`Navigation timeout: ${e.message}`);
      return null;
    });

    await signInBtn.click();
    await navigationPromise;

    await page.waitForTimeout(3000);
    await page.screenshot({ path: path.join(screenshotDir, '06-after-sign-in.png'), fullPage: true });
    console.log(`URL after sign in: ${page.url()}`);

    // Step 7: Capture final state
    console.log('--- Step 7: Final state ---');
    const finalCookies = await page.context().cookies();
    console.log('Final cookies:', JSON.stringify(finalCookies, null, 2));

    const finalUrl = page.url();
    console.log(`Final URL: ${finalUrl}`);

    // Write diagnostics to file
    const diagnostics = {
      finalUrl,
      initialCookies,
      finalCookies,
      consoleLogs,
      networkRequests: networkRequests.filter((r) =>
        r.url.includes('/auth/') || r.url.includes('/session') || r.url.includes('/login') || r.status !== 200
      ),
      allNetworkRequests: networkRequests.map((r) => `${r.method} ${r.status} ${r.url}`),
    };
    fs.writeFileSync(
      path.join(screenshotDir, 'diagnostics.json'),
      JSON.stringify(diagnostics, null, 2)
    );

    // Step 8: Verify we left the login page
    expect(finalUrl).not.toContain('/login');
  });

  test('login succeeds even if tenant-slug cookie is cleared before dashboard load', async ({ page }) => {
    // This test simulates the Chrome scenario where browser extensions or
    // cookie blockers prevent the tenant-slug cookie from persisting.

    // Collect URL changes to detect redirect loops
    const urlHistory: string[] = [];
    page.on('framenavigated', (frame) => {
      if (frame === page.mainFrame()) {
        urlHistory.push(frame.url());
      }
    });

    // Step 1: Navigate to login
    await page.goto('/login', { waitUntil: 'networkidle', timeout: 30000 });

    // Step 2: Complete login flow
    const emailInput = page.locator('input[type="email"], input[name="email"], input[placeholder*="email" i]');
    await expect(emailInput).toBeVisible({ timeout: 10000 });
    await emailInput.fill(EMAIL);

    const continueBtn = page.locator('button:has-text("Continue"), button:has-text("Next"), button[type="submit"]').first();
    await continueBtn.click();

    const passwordInput = page.locator('input[type="password"], input[name="password"]');
    await expect(passwordInput).toBeVisible({ timeout: 30000 });
    await passwordInput.fill(PASSWORD);

    const signInBtn = page.locator('button:has-text("Sign In")');
    await expect(signInBtn).toBeEnabled({ timeout: 10000 });

    // Before clicking Sign In, set up interception to clear tenant-slug cookie
    // after the login succeeds but before the redirect completes
    await page.context().addCookies([{
      name: 'tenant-slug',
      value: '',
      domain: 'admin.yahvismartfarm.com',
      path: '/',
      expires: 0, // Expire immediately
    }]);

    const navigationPromise = page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 30000 }).catch(() => null);
    await signInBtn.click();

    // Clear the tenant-slug cookie after login API succeeds but before redirect
    await page.waitForResponse((r) => r.url().includes('/auth/direct/admin/login') && r.status() === 200);
    // Delete the tenant-slug cookie to simulate Chrome extension blocking it
    await page.context().clearCookies({ name: 'tenant-slug' });

    await navigationPromise;
    await page.waitForTimeout(5000);

    const finalUrl = page.url();
    console.log(`Final URL (no tenant cookie): ${finalUrl}`);
    console.log(`URL history: ${JSON.stringify(urlHistory)}`);

    await page.screenshot({ path: path.join(screenshotDir, '07-no-tenant-cookie.png'), fullPage: true });

    // Should NOT be on login page (no redirect loop)
    expect(finalUrl).not.toContain('/login');
    // Should NOT be on localhost (the old bug)
    expect(finalUrl).not.toContain('localhost');
    // Should still be on the custom domain
    expect(finalUrl).toContain('admin.yahvismartfarm.com');
  });
});
