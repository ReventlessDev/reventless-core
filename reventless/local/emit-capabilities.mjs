#!/usr/bin/env node
// Emit `capabilities.json` beside a plugin's generated `Plugin.res`.
//
// Applies the plugin's compiled composition root to the local platform and
// renders the structure-derived capability manifest — the same
// `pluginStructure.requiredStores` walk the deployed plugin reports at
// runtime, never a second scan of the sources. Untyped by necessity: a
// dynamically imported module cannot be functor-applied from ReScript, so the
// reflection lives here and everything typed lives in
// `Reventless.CapabilityManifest`.
//
// Usage: emit-capabilities <srcDir>   (run from the plugin package, after `rescript build`)

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

// The local platform defaults to Debug-level logging; a build step should not.
if (process.env.LOG_LEVEL === undefined) process.env.LOG_LEVEL = "warn";

const srcDirArg = process.argv[2];
if (srcDirArg === undefined || srcDirArg === "") {
  console.error("Usage: emit-capabilities <srcDir>");
  process.exit(1);
}

const srcDir = path.resolve(srcDirArg);
const pluginModulePath = path.join(srcDir, "Plugin.res.mjs");
if (!fs.existsSync(pluginModulePath)) {
  console.error(
    `emit-capabilities: ${pluginModulePath} not found — run \`rescript build\` first.`,
  );
  process.exit(1);
}

const LocalPlatform = await import(
  new URL("./src/Platform.res.mjs", import.meta.url)
);
const CapabilityManifest = await import(
  "@reventlessdev/reventless-spec/src/components/CapabilityManifest.res.mjs"
);

const Platform = LocalPlatform.Make();
const Plugin = await import(pathToFileURL(pluginModulePath));
const { pluginStructure } = Plugin.Make(Platform);

const manifestPath = path.join(srcDir, "capabilities.json");
fs.writeFileSync(manifestPath, CapabilityManifest.renderForStructure(pluginStructure));
console.log("Generated: " + manifestPath);

// Applying the platform functor wires in-process infrastructure; exit
// explicitly so no lingering handle keeps the build step alive.
process.exit(0);
