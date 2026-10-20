// Optional real-browser regression (Playwright installed outside this repo).
// NODE_PATH=<playwright node_modules> node src/test/login-layout.browser.cjs <local /login URL> <output directory>
// Start Vite with synthetic VITE_SUPABASE_* process values; no .env or live credentials.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

async function verify() {
  const url = process.argv[2] || 'http://127.0.0.1:3007/login';
  assert.ok(['localhost', '127.0.0.1'].includes(new URL(url).hostname), 'Local server only');
  const output = path.resolve(process.argv[3] || 'login-evidence');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage();
    const results = [];
    for (const [width, height] of [[1920, 1080], [1366, 768], [390, 844]]) {
      await page.setViewportSize({ width, height });
      await page.emulateMedia({ reducedMotion: 'no-preference' });
      await page.goto(url);
      await page.getByRole('button', { name: 'Entrar' }).waitFor();
      await page.evaluate(() => document.fonts.ready);
      const layout = await page.evaluate(() => {
        const rect = (selector) => document.querySelector(selector).getBoundingClientRect().toJSON();
        const art = rect('[data-testid="login-art"]');
        return {
          width: innerWidth, height: innerHeight,
          scrollHeight: document.documentElement.scrollHeight,
          scrollWidth: document.documentElement.scrollWidth,
          main: rect('main'), block: rect('main > div'), art,
          visibleClouds: [...document.querySelectorAll('.login-cloud-shape')].filter((cloud) => {
            const r = cloud.getBoundingClientRect();
            return r.bottom > art.top && r.top < art.bottom && r.right > art.left && r.left < art.right;
          }).length,
        };
      });
      assert.equal(layout.scrollHeight, height, 'No vertical page scroll');
      assert.equal(layout.scrollWidth, width, 'No horizontal page scroll');
      assert.equal(layout.visibleClouds, 5, 'Clouds remain distributed inside artwork');
      assert.ok(Math.abs(layout.block.y + layout.block.height / 2 - (layout.main.y + layout.main.height / 2)) < 1, 'Vertical center');
      assert.ok(Math.abs(layout.block.x + layout.block.width / 2 - (layout.main.x + layout.main.width / 2)) < 1, 'Horizontal center');
      if (width < 1024) assert.ok(layout.art.bottom <= layout.block.top, 'Mobile art cannot cover form/logo');
      await page.screenshot({ path: path.join(output, `after-${width}x${height}.png`), fullPage: true });
      const transforms = () => page.locator('.login-cloud').evaluateAll((clouds) => clouds.map((cloud) => getComputedStyle(cloud).transform));
      const moving = await transforms();
      await page.waitForTimeout(500);
      assert.notDeepEqual(await transforms(), moving, 'Clouds drift');
      await page.emulateMedia({ reducedMotion: 'reduce' });
      const stopped = await transforms();
      await page.waitForTimeout(500);
      assert.deepEqual(await transforms(), stopped, 'Reduced motion stops drift');
      assert.deepEqual(await page.locator('.login-cloud').evaluateAll((clouds) => clouds.map((cloud) => getComputedStyle(cloud).animationName)), Array(5).fill('none'));
      await page.screenshot({ path: path.join(output, `reduced-${width}x${height}.png`), fullPage: true });
      results.push({ ...layout, motion: 'PASS', reducedMotion: 'PASS' });
    }
    await page.reload();
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').getAttribute('id'), 'email');
    await page.keyboard.type('qa@example.com');
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').getAttribute('id'), 'password');
    await page.keyboard.type('test-password');
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').textContent(), 'Entrar');
    assert.notEqual(await page.locator(':focus').evaluate((e) => getComputedStyle(e).boxShadow), 'none');
    await page.keyboard.press('Shift+Tab');
    assert.equal(await page.locator(':focus').getAttribute('id'), 'password');
    await page.route('**/auth/v1/token**', (route) => route.fulfill({
      status: 400, contentType: 'application/json',
      body: JSON.stringify({ error_code: 'invalid_credentials', code: 'invalid_credentials', message: 'Invalid login credentials' }),
    }));
    await page.keyboard.press('Enter');
    await page.getByRole('alert').waitFor();
    assert.match(await page.getByRole('alert').textContent(), /E-mail ou senha incorretos/);
    const report = { results, keyboard: 'Tab, Shift+Tab, focus, Enter and inline alert PASS' };
    fs.writeFileSync(path.join(output, 'visual-results.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));
  } finally {
    await browser.close();
  }
}
verify().catch((error) => { console.error(error); process.exitCode = 1; });
