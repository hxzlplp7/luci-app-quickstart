import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const bundlePath = path.resolve(__dirname, "../htdocs/luci-static/dashboard/index.js");
const code = fs.readFileSync(bundlePath, "utf8");

assert.match(
  code,
  /Promise\.allSettled\(\[S\.Nas\.Disk\.Status\.GET\(\), S\.Raid\.List\.GET\(\)\]\)/,
  "Homepage disk initialization should tolerate a NAS or RAID API failure instead of white-screening the dashboard."
);

assert.doesNotMatch(
  code,
  /\(\(\) => T\(this, null, function\* \(\) \{\s*const b = yield Promise\.all\(\[S\.Nas\.Disk\.Status\.GET\(\), S\.Raid\.List\.GET\(\)\]\);/s,
  "Homepage disk initialization still awaits Promise.all without a guard."
);
