// Full-page screenshot via the playwright package cached under monet npx.
// Driven by take-screenshot.sh. argv: <url> <outpath>
// MONET_HOME resolution mirrors lib/monet-env.sh: an explicit env var wins,
// otherwise the parent of this file's directory (the running checkout).
const path = require("path");
const MONET_HOME = process.env.MONET_HOME || path.dirname(__dirname);
const PW = process.env.MONET_PLAYWRIGHT_PKG ||
  path.join(MONET_HOME, ".npm/_npx/9833c18b2d85bc59/node_modules/playwright");
const CHROME = process.env.MONET_CHROME_BIN ||
  path.join(MONET_HOME, ".cache/ms-playwright/chromium-1187/chrome-linux/chrome");
const { chromium } = require(PW);
(async () => {
  const b = await chromium.launch({
    headless: true,
    executablePath: CHROME,
    args: ["--no-sandbox", "--disable-gpu"],
  });
  const c = await b.newContext({
    viewport: { width: 1280, height: 720 },
    userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  });
  const p = await c.newPage();
  await p.goto(process.argv[2], { waitUntil: "domcontentloaded", timeout: 30000 });
  await p.waitForTimeout(3000);
  await p.screenshot({ path: process.argv[3], fullPage: true });
  await b.close();
})().catch((e) => { console.error(e.message); process.exit(1); });
