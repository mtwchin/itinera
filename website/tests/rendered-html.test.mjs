import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the Itinera campaign page", async () => {
  const previousSiteUrl = process.env.SITE_URL;
  process.env.SITE_URL = "https://itinera.example";
  const response = await render();
  if (previousSiteUrl === undefined) {
    delete process.env.SITE_URL;
  } else {
    process.env.SITE_URL = previousSiteUrl;
  }
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Itinera — A field guide for the trip you actually take<\/title>/i);
  assert.match(html, /A field guide for the trip you actually take/);
  assert.match(html, /Shaped around your stay/);
  assert.match(html, /A route, not a list/);
  assert.match(html, /Ready when the day starts/);
  assert.match(html, /Private by default/);
  assert.match(html, /Preparing for TestFlight|TestFlight/);
  assert.match(html, /<nav[^>]*aria-label="Main navigation"/i);
  assert.match(html, /<main id="top">/i);
  assert.match(html, /property="og:image" content="https:\/\/itinera\.example\/og\.png"/i);
  assert.match(html, /name="twitter:card" content="summary_large_image"/i);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
});

test("removes starter-only code and metadata", async () => {
  const [page, layout, packageJson] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
  ]);

  assert.match(page, /id="features"/);
  assert.match(page, /id="how-it-works"/);
  assert.match(page, /id="on-the-road"/);
  assert.match(page, /Illustrative itinerary/);
  assert.match(layout, /const title = "Itinera/);
  assert.match(layout, /generateMetadata/);
  assert.match(layout, /process\.env\.SITE_URL/);
  assert.match(layout, /app-icon\.png/);
  assert.match(layout, /og\.png/);
  assert.doesNotMatch(layout, /codex-preview|Starter Project|_sites-preview/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);

  await assert.rejects(access(new URL("../app/_sites-preview", import.meta.url)));
});
