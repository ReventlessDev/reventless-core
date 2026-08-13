let dirname = NodeImportMeta.dirname

let pathToLayerData = NodePath.resolve([dirname, "../builder/layer/"])
let pathToSavedDependencies = NodePath.resolve([dirname, "../builder/layer/nodejs/node_modules"])

let sourcePackageVersion =
  NodeProcess.env->Dict.get("REVENTLESS_AWS_VERSION")->Option.getOr("latest")

let config: DependencyBundler_Config.t = {
  sourcePackageName: "@reventlessdev/reventless-aws",
  sourcePackageVersion,
  pathToLayerData,
  pathToSavedDependencies,
  excludeScopes: [
    "pulumi",
    "types",
    "opentelemetry",
    // @aws-sdk/* clients are excluded (bundled per-Lambda in /var/task, or
    // provided by the runtime) — but their @smithy/* transitives must stay in
    // the layer (see includeScopes below), because the Lambdas resolve @smithy
    // from /opt/nodejs/node_modules at runtime.
    "aws-sdk",
    "sigstore",
    "npmcli",
    "gar",
  ],
  includeScopes: [
    // Keep the full @smithy/* closure. Its only prod dependents are the
    // scope-excluded @aws-sdk/* clients, so the orphan pruning would otherwise
    // strip all but a handful — the exact cause of the upload presign Lambda's
    // `Cannot find module '@smithy/middleware-endpoint'` cold-start crash.
    "smithy",
  ],
  includeModules: [
    // @rescript/runtime is a transitive dep of rescript (excluded as build tool)
    // but is required at runtime by all compiled ReScript code
    "@rescript/runtime",
  ],
  excludeModules: [
    "aws-sdk",
    "sury-ppx",
    "fast-check",
    // SSH stack (deploy-time Cloner only)
    "ssh2",
    "tweetnacl",
    "bcrypt-pbkdf",
    "asn1",
    // esbuild — was used for deploy-time bundling, replaced by compiled EntryPoint modules
    "esbuild",
    // Pulumi ReScript bindings — deploy-time only, no entry point imports them
    "@reventlessdev/rescript-pulumi-pulumi",
    "@reventlessdev/rescript-pulumi-aws",
    // Build/parse tools not needed at runtime
    "esprima",
    "acorn",
    "source-map",
    "source-map-support",
    "cjs-module-lexer",
    // Process spawning (unavailable in Lambda)
    "execa",
    "cross-spawn",
    "shebang-command",
    "shebang-regex",
    // npm infrastructure (transitive from excluded @npmcli)
    "cacache",
    "make-fetch-happen",
    "ssri",
    "minipass-fetch",
    "minipass-collect",
    "minipass-flush",
    "minipass-pipeline",
    "minipass-sized",
    "socks",
    "socks-proxy-agent",
    "http-proxy-agent",
    "https-proxy-agent",
    "hosted-git-info",
    "npm-install-checks",
    "npm-normalize-package-bin",
    "npm-package-arg",
    "npm-pick-manifest",
    "validate-npm-package-name",
    "spdx-exceptions",
    "spdx-expression-parse",
    "spdx-license-ids",
    // Testing
    "pure-rand",
    // Unused at runtime (transitive deps only)
    "ramda",
    "lodash",
    "graphql",
    "jsonschema2graphql",
    // Orphan transitives — not imported by any package in the layer
    "debug",
    "ms",
    "semver",
    "graceful-fs",
    "js-yaml",
    "argparse",
    "camelcase",
    "escalade",
    "proc-log",
    "ansi-regex",
    "ansi-styles",
    "strip-ansi",
    "color-convert",
    "color-name",
    "merge-stream",
    "signal-exit",
    "module-details-from-path",
    "punycode",
    "wrappy",
    "once",
    "function-bind",
    "hasown",
    "is-core-module",
    "path-parse",
    "resolve",
    "supports-preserve-symlinks-flag",
    "safer-buffer",
    "sprintf-js",
    "type-fest",
    "inherits",
    "minipass",
    "minizlib",
  ],
  // @reventlessdev/* are public on npmjs — anonymous install, no auth token.
  registryOpts: Dict.fromArray([
    ("@reventlessdev:registry", "https://registry.npmjs.org"),
  ]),
  rootPostProcess: DependencyBundler_PostProcess.reventlessAwsDeploytime,
  postProcess: Dict.fromArray([
    (">rescript", DependencyBundler_PostProcess.rescriptDependent),
    ("@reventlessdev/reventless-core", DependencyBundler_PostProcess.reventlessCoreDeploytime),
    ("@reventlessdev/rescript-effect", DependencyBundler_PostProcess.deleteTests),
    ("effect", DependencyBundler_PostProcess.deleteEffectSrc),
    ("@reventlessdev/rescript-fast-csv", DependencyBundler_PostProcess.deleteTestsAndExamples),
    ("fast-csv", DependencyBundler_PostProcess.deleteTestsAndExamples),
  ]),
}

// Await the build and exit non-zero on failure. Discarding the promise (the
// previous shape) surfaced failures only as an unhandledRejection, so CI saw a
// green exit even when the layer build threw.
let _ =
  DependencyBundler.build(config)->Promise.catch(e => {
    Console.error2("layer build failed:", e)
    NodeProcess.exit(1)
    Promise.resolve()
  })
