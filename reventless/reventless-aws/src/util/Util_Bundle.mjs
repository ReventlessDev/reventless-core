import * as path from "path";
import * as fs from "fs";
import * as crypto from "crypto";
import * as pulumi from "@pulumi/pulumi";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

/**
 * Convert an import.meta.url file URL to an npm module specifier.
 * Walks up from the file to find the nearest package.json, reads the package name,
 * and constructs the npm specifier from packageName + relative path.
 *
 * @param {string} importMetaUrl - file:// URL from import.meta.url
 * @returns {string} - npm specifier (e.g. "@reventlessdev/catalog/src/Category.res.mjs")
 */
export function getModuleSpecifier(importMetaUrl) {
  const filePath = new URL(importMetaUrl).pathname;
  let dir = path.dirname(filePath);
  while (dir !== "/") {
    const pkgPath = path.join(dir, "package.json");
    if (fs.existsSync(pkgPath)) {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf-8"));
      if (pkg.name) {
        const relPath = path.relative(dir, filePath);
        return pkg.name + "/" + relPath;
      }
    }
    dir = path.dirname(dir);
  }
  throw new Error(`No package.json found for ${filePath}`);
}

/**
 * Extract the npm package name from a module specifier.
 * Handles scoped packages (@scope/pkg/path) and unscoped (pkg/path).
 *
 * @param {string} specifier - Module specifier (e.g. "@reventlessdev/catalog/src/Foo.res.mjs")
 * @returns {string} - Package name (e.g. "@reventlessdev/catalog")
 */
export function extractPackageName(specifier) {
  const parts = specifier.split("/");
  if (specifier.startsWith("@")) {
    return parts[0] + "/" + parts[1];
  }
  return parts[0];
}

/**
 * Resolve the root directory of an npm package.
 *
 * @param {string} packageName - Package name (e.g. "@reventlessdev/catalog")
 * @returns {string} - Absolute path to package root directory
 */
export function resolvePackageRoot(packageName) {
  const pkgJsonPath = require.resolve(packageName + "/package.json");
  return path.dirname(pkgJsonPath);
}

/**
 * Compute a SHA256 hash of a string, returned as base64.
 *
 * @param {string} str - Input string
 * @returns {string} - Base64-encoded SHA256 hash
 */
export function hashString(str) {
  return crypto.createHash("sha256").update(str).digest("base64");
}

/**
 * Create a filtered AssetArchive from a package directory.
 * Only includes runtime-essential files: *.res.mjs and package.json.
 * Excludes lib/, tests/, __mocks__/, *.res, CHANGELOG, README, node_modules/, etc.
 *
 * @param {string} packageRoot - Absolute path to package root directory
 * @returns {pulumi.asset.AssetArchive} - Archive with only runtime files
 */
export function createFilteredPackageArchive(packageRoot) {
  const assets = {};

  function walk(dir, prefix) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const name = entry.name;
      // Skip non-runtime directories
      if (entry.isDirectory()) {
        if (
          name === "node_modules" ||
          name === "lib" ||
          name === "tests" ||
          name === "test" ||
          name === "__mocks__" ||
          name === "__tests__" ||
          name === ".git" ||
          name === "coverage"
        ) {
          continue;
        }
        walk(path.join(dir, name), prefix ? prefix + "/" + name : name);
        continue;
      }
      // Include only *.res.mjs and package.json
      if (name === "package.json" || name.endsWith(".res.mjs")) {
        const relPath = prefix ? prefix + "/" + name : name;
        assets[relPath] = new pulumi.asset.FileAsset(path.join(dir, name));
      }
    }
  }

  walk(packageRoot, "");
  return new pulumi.asset.AssetArchive(assets);
}
