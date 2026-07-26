type postProcessMap = Dict.t<DependencyBundler_PostProcess.postProcessFn>

type t = {
  sourcePackageName: string,
  sourcePackageVersion: string,
  pathToLayerData: string,
  pathToSavedDependencies: string,
  excludeScopes: array<string>,
  excludeModules: array<string>,
  includeModules?: array<string>,
  includeScopes?: array<string>,
  registryOpts: Dict.t<string>,
  postProcess: postProcessMap,
  rootPostProcess?: DependencyBundler_PostProcess.postProcessFn,
}
