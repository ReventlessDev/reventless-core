import * as path from "path";
import * as fs from "fs";
import * as crypto from "crypto";
import * as pulumi from "@pulumi/pulumi";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

// Cache populated by getModuleSpecifier: packageName → absolute package root dir.
// Allows resolvePackageRoot to find packages that aren't resolvable via require
// (e.g. the deploy stack's own package, which is not a workspace member).
const packageRootCache = new Map();

/**
 * Convert an import.meta.url file URL to an npm module specifier.
 * Walks up from the file to find the nearest package.json, reads the package name,
 * and constructs the npm specifier from packageName + relative path.
 *
 * @param {string} importMetaUrl - file:// URL from import.meta.url
 * @returns {string} - npm specifier (e.g. "@reventlessdev/catalog/src/Category.res.mjs")
 */
export function getModuleSpecifier(importMetaUrl) {
  // If it's already a package specifier (not a file:// URL), return it directly.
  if (!importMetaUrl.startsWith("file://")) {
    return importMetaUrl;
  }
  const filePath = new URL(importMetaUrl).pathname;
  let dir = path.dirname(filePath);
  while (dir !== "/") {
    const pkgPath = path.join(dir, "package.json");
    if (fs.existsSync(pkgPath)) {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf-8"));
      if (pkg.name) {
        packageRootCache.set(pkg.name, dir);
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
  // Fast path: populated by getModuleSpecifier when it walks the package tree.
  if (packageRootCache.has(packageName)) {
    return packageRootCache.get(packageName);
  }
  try {
    const pkgJsonPath = require.resolve(packageName + "/package.json");
    return path.dirname(pkgJsonPath);
  } catch (_e) {
    const cwdRequire = createRequire(process.cwd() + "/index.js");
    const pkgJsonPath = cwdRequire.resolve(packageName + "/package.json");
    return path.dirname(pkgJsonPath);
  }
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
 * Build a Lambda code AssetArchive with a static re-export entry point and optional user packages.
 * Centralises the archive-building pattern used by every runtime builder.
 *
 * @param {string} entryPointModule - npm specifier of the entry point to re-export
 *   (e.g. "@reventlessdev/reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs")
 * @param {Object} packageDirs - { [pkgName]: pkgRoot } — user packages to bundle under node_modules/.
 *   Pass an empty object when all imports are satisfied by the Lambda Layer.
 * @returns {{ code: pulumi.asset.AssetArchive, sourceCodeHash: string }}
 */
export function buildCodeArchive(entryPointModule, packageDirs) {
  const reExportCode = `export { handler } from "${entryPointModule}";`;
  const archiveContents = {};
  archiveContents["index.mjs"] = new pulumi.asset.StringAsset(reExportCode);
  for (const [pkgName, pkgRoot] of Object.entries(packageDirs)) {
    archiveContents[`node_modules/${pkgName}`] = createFilteredPackageArchive(pkgRoot);
  }
  const code = new pulumi.asset.AssetArchive(archiveContents);
  const sourceCodeHash = hashString(reExportCode + Object.keys(packageDirs).join(","));
  return { code, sourceCodeHash };
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
      // Include *.mjs (both compiled *.res.mjs and hand-written entry points) and package.json
      if (name === "package.json" || name.endsWith(".mjs")) {
        const relPath = prefix ? prefix + "/" + name : name;
        assets[relPath] = new pulumi.asset.FileAsset(path.join(dir, name));
      }
    }
  }

  walk(packageRoot, "");
  return new pulumi.asset.AssetArchive(assets);
}
