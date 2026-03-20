import * as esbuild from "esbuild";
import * as path from "path";
import * as fs from "fs";
import * as os from "os";
import * as crypto from "crypto";
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
    external: [
      "@aws-sdk/*",
      // Layer-provided packages — must match what reventless-layer-builder produces.
      // User domain code (Spec, Behavior) is resolved via absolute paths and won't match.
      "effect",
      "effect/*",
      "sury",
      "sury/*",
      "@reventlessdev/*",
      "@rescript/*",
      "@standard-schema/*",
      "uuid",
      "hash-object",
    ],
    // Resolve dependencies from the project root so temp-dir entry points
    // can find packages like "effect", "@reventlessdev/*", etc.
    absWorkingDir: projectRoot,
    nodePaths: [path.join(projectRoot, "node_modules")],
    banner: {
      js: `import { createRequire } from 'module'; const require = createRequire(import.meta.url);`,
    },
    minify: true,
    sourcemap: false,
  });

  if (result.errors.length > 0) {
    throw new Error(`esbuild bundling failed: ${JSON.stringify(result.errors)}`);
  }

  // Read bundled output as string — StringAsset is path-independent,
  // so Pulumi only sees content changes, not temp directory path changes.
  const bundledCode = fs.readFileSync(outPath, "utf-8");

  // Clean up temp directory — content is in memory now
  fs.rmSync(tmpDir, { recursive: true, force: true });

  const sourceCodeHash = crypto
    .createHash("sha256")
    .update(bundledCode)
    .digest("base64");


  return {
    code: new pulumi.asset.AssetArchive({
      "index.mjs": new pulumi.asset.StringAsset(bundledCode),
    }),
    sourceCodeHash,
  };
}

/**
 * Create a stable temp directory based on content hash.
 * esbuild embeds the entry point path as a comment in its output,
 * so a random temp dir name causes non-deterministic bundles.
 */
function stableTmpDir(content) {
  const hash = crypto.createHash("sha256").update(content).digest("hex").slice(0, 16);
  const dir = path.join(os.tmpdir(), `reventless-bundle-${hash}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
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
  const wrapperCode = `import { ${exportName} } from ${JSON.stringify(entryPoint)};
export const handler = ${exportName};
`;
  const tmpDir = stableTmpDir(wrapperCode);
  const wrapperPath = path.join(tmpDir, "wrapper.mjs");
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
  const tmpDir = stableTmpDir(entryPointCode);
  const wrapperPath = path.join(tmpDir, "wrapper.mjs");

  fs.writeFileSync(wrapperPath, entryPointCode);

  return buildAndArchive(wrapperPath);
}
