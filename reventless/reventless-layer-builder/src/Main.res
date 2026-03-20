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
    "smithy",
    "sigstore",
    "npmcli",
    "gar",
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
  ],
  registryOpts: Dict.fromArray([
    ("@reventlessdev:registry", "https://npm.pkg.github.com"),
    (
      "//npm.pkg.github.com/:_authToken",
      env->Dict.get("NPM_GITHUB_TOKEN")->Option.orElse(env->Dict.get("NODE_AUTH_TOKEN"))->Option.getOr(""),
    ),
  ]),
  postProcess: Dict.fromArray([
    (">rescript", DependencyBundler_PostProcess.rescriptDependent),
    ("@reventlessdev/reventless-core", DependencyBundler_PostProcess.reventlessCore),
    ("@reventlessdev/rescript-effect", DependencyBundler_PostProcess.deleteTests),
    ("effect", DependencyBundler_PostProcess.deleteEffectSrc),
    ("@reventlessdev/rescript-fast-csv", DependencyBundler_PostProcess.deleteTestsAndExamples),
    ("fast-csv", DependencyBundler_PostProcess.deleteTestsAndExamples),
  ]),
}

let _ = DependencyBundler.build(config)
