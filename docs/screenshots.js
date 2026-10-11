// Regenerates the README screenshots of the status page from webui/ and
// sample /status data. Needs Node and Playwright:
//   npm install --no-save playwright && npx playwright install chromium
//   node docs/screenshots.js webui docs/images
const http = require("http");
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const [webui, outDir] = process.argv.slice(2).map((p) => path.resolve(p));
const now = Date.now() / 1000;
const sample = {
  healthy: true, status: "syncing", raw_status: "Syncing 1,204 files • 3 mins",
  sync: { syncing: 1204, downloading: 1180, uploading: 24 },
  account: { linked: true },
  daemon: { version: "272.4.3798", uptime_seconds: 3 * 86400 + 5 * 3600, memory_mb: 612.4, restart_count: 0 },
  last_sync: now - 1500, last_error: null,
  excluded_folders: ["Camera Uploads", "Archive"],
  image: { version: "1.3.0", revision: "c50898d226606e10" },
};
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };
const server = http.createServer((req, res) => {
  if (req.url.startsWith("/status")) {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify(sample));
  }
  const file = req.url === "/" ? "index.html" : req.url.slice(1);
  const p = path.join(webui, file);
  if (!p.startsWith(webui) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[path.extname(p)] });
  res.end(fs.readFileSync(p));
});

server.listen(0, "127.0.0.1", async () => {
  const url = `http://127.0.0.1:${server.address().port}/`;
  const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
  const shots = [
    ["status-page-light.png", { width: 760, height: 640 }, "light"],
    ["status-page-dark.png", { width: 760, height: 640 }, "dark"],
  ];
  for (const [name, viewport, colorScheme] of shots) {
    const page = await browser.newPage({ viewport, colorScheme, deviceScaleFactor: 2 });
    await page.goto(url);
    await page.waitForSelector(".pill.busy");
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
    console.log(name, "horizontal overflow:", overflow);
    await page.screenshot({ path: path.join(outDir, name), fullPage: true });
    await page.close();
  }
  await browser.close();
  server.close();
});
