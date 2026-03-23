@val @scope("process")
external env: Dict.t<string> = "env"

@module("node:url")
external fileURLToPath: string => string = "fileURLToPath"

@val @scope(("import", "meta"))
external importMetaUrl: string = "url"

let dirname = importMetaUrl->fileURLToPath->NodePath.dirname

let pathToLayerData = NodePath.resolve([dirname, "../builder/layer/"])
let pathToSavedDependencies = NodePath.resolve([dirname, "../builder/layer/nodejs/node_modules"])

let sourcePackageVersion =
  env->Dict.get("REVENTLESS_AWS_VERSION")->Option.getOr("latest")

let config: DependencyBundler_Config.t = {
  sourcePackageName: "@reventlessdev/reventless-aws",
  sourcePackageVersion,
  pathToLayerData,
  pathToSavedDependencies,
  excludeScopes: [
    "pulumi",
    "types",
    "opentelemetry",
    "aws-sdk",
    // @smithy/* is provided by the Lambda runtime, but ESM imports from
    // layer code cannot resolve it via NODE_PATH. Include it in the layer
    // so ESM resolution finds it under /opt/nodejs/node_modules/.
    "sigstore",
    "npmcli",
    "gar",
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
  registryOpts: Dict.fromArray([
    ("@reventlessdev:registry", "https://npm.pkg.github.com"),
    (
      "//npm.pkg.github.com/:_authToken",
      env->Dict.get("NPM_GITHUB_TOKEN")->Option.orElse(env->Dict.get("NODE_AUTH_TOKEN"))->Option.getOr(""),
    ),
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

let _ = DependencyBundler.build(config)
