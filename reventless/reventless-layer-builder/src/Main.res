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
  excludeScopes: ["pulumi", "types", "opentelemetry", "aws-sdk", "smithy", "sigstore"],
  excludeModules: ["aws-sdk", "sury-ppx", "fast-check"],
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
  ]),
}

let _ = DependencyBundler.build(config)
