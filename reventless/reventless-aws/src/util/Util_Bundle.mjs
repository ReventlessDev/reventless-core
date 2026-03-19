import * as esbuild from "esbuild";
import * as path from "path";
import * as fs from "fs";
import * as os from "os";
import * as pulumi from "@pulumi/pulumi";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

/**
 * Find the project root by walking up from this file until we find node_modules.
 * Used so esbuild can resolve dependencies when bundling from temp directories.
 */
function findProjectRoot() {
  let dir = path.dirname(new URL(import.meta.url).pathname);
  while (dir !== "/") {
    const candidate = path.join(dir, "node_modules");
    if (fs.existsSync(candidate)) {
      return dir;
    }
    dir = path.dirname(dir);
  }
  return process.cwd();
}

const projectRoot = findProjectRoot();

/**
 * Resolve a module specifier to an absolute file path.
 * Works for package names, relative paths, and scoped packages.
 *
 * @param {string} specifier - Module specifier (e.g. "@reventlessdev/reventless-aws/src/...")
 * @returns {string} - Absolute file path
 */
export function resolveModule(specifier) {
  return require.resolve(specifier);
}

/**
 * Run esbuild on a wrapper file and return an AssetArchive.
 * Internal helper shared by bundleHandler and bundleEntryPoint.
 */
function buildAndArchive(wrapperPath) {
  const tmpDir = path.dirname(wrapperPath);
  const outPath = path.join(tmpDir, "index.mjs");

  const result = esbuild.buildSync({
    entryPoints: [wrapperPath],
    bundle: true,
    outfile: outPath,
    format: "esm",
    platform: "node",
    target: "node22",
    external: ["@aws-sdk/*"],
    // Resolve dependencies from the project root so temp-dir entry points
    // can find packages like "effect", "@reventlessdev/*", etc.
    absWorkingDir: projectRoot,
    nodePaths: [path.join(projectRoot, "node_modules")],
    banner: {
      js: `import { createRequire } from 'module'; const require = createRequire(import.meta.url);`,
    },
    minify: false,
    sourcemap: false,
  });

  if (result.errors.length > 0) {
    throw new Error(`esbuild bundling failed: ${JSON.stringify(result.errors)}`);
  }

  return new pulumi.asset.AssetArchive({
    "index.mjs": new pulumi.asset.FileAsset(outPath),
  });
}

/**
 * Bundle a handler module into a self-contained Lambda deployment package.
 * Creates a wrapper that re-exports the named export as "handler".
 *
 * @param {string} entryPoint - Absolute path to the compiled .res.mjs handler module
 * @param {string} exportName - The exported function name (e.g. "handleQueueEvent")
 * @returns {pulumi.asset.AssetArchive} - Archive containing the bundled index.mjs
 */
export function bundleHandler(entryPoint, exportName) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "reventless-bundle-"));
  const wrapperPath = path.join(tmpDir, "wrapper.mjs");

  const wrapperCode = `import { ${exportName} } from ${JSON.stringify(entryPoint)};
export const handler = ${exportName};
`;
  fs.writeFileSync(wrapperPath, wrapperCode);

  return buildAndArchive(wrapperPath);
}

/**
 * Bundle an arbitrary entry point string into a Lambda deployment package.
 * Use this for handlers that need custom setup (e.g. reading env vars,
 * composing multiple imports, calling factory functions).
 *
 * The entryPointCode must export a `handler` function.
 *
 * @param {string} entryPointCode - JavaScript module code to bundle
 * @returns {pulumi.asset.AssetArchive} - Archive containing the bundled index.mjs
 */
export function bundleEntryPoint(entryPointCode) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "reventless-bundle-"));
  const wrapperPath = path.join(tmpDir, "wrapper.mjs");

  fs.writeFileSync(wrapperPath, entryPointCode);

  return buildAndArchive(wrapperPath);
}
