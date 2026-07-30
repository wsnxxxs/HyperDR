/* Node bridge used by test_curve_port.py.
 *
 * The production tree intentionally has no package.json. Import the pure
 * browser module through a data URL so this runner works without changing the
 * panel's packaging or Node's default .js module mode.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repository = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const modulePath = path.join(
  repository, "apps", "panel", "web", "js", "preview", "curve-math.js");
const source = fs.readFileSync(modulePath, "utf8");
const curveMath = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

let input = "";
for await (const chunk of process.stdin) input += chunk;
const cases = JSON.parse(input);
const curves = cases.map((settings) => {
  const table = new Float32Array(settings.samples ?? 257);
  curveMath.fillPhotographicGainLut(table, settings);
  return Array.from(table);
});
process.stdout.write(JSON.stringify(curves));
