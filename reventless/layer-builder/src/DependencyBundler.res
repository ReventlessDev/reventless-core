// Returns false when the post-processing step failed. The caller tracks this so
// the overall build can exit non-zero — previously a failed step was logged and
// the build still "succeeded", shipping unstripped deploy-time/test code.
let doPostProcessing = async (node, pathToSavedDependencies, fn, spinner): bool => {
  let cwd = NodePath.resolve([pathToSavedDependencies, "../" ++ node->Arborist.location])
  let fnName = %raw(`fn.name`)
  let _ = spinner->Ora.start("postprocess " ++ node->Arborist.name ++ ": " ++ fnName)
  Console.log("")
  try {
    await fn(node, cwd)
    let _ = spinner->Ora.succeed(())
    true
  } catch {
  | exn => {
      let _ = spinner->Ora.fail(())
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      Console.error2("postprocessing of " ++ node->Arborist.name ++ " did fail at '" ++ fnName ++ "':", msg)
      false
    }
  }
}

let build = async (config: DependencyBundler_Config.t) => {
  let {
    sourcePackageName,
    sourcePackageVersion,
    pathToLayerData,
    pathToSavedDependencies,
    excludeScopes,
    excludeModules,
    ?includeModules,
    ?includeScopes,
    postProcess,
    ?rootPostProcess,
    registryOpts,
  } = config
  let includeModules = includeModules->Option.getOr([])
  let includeScopes = includeScopes->Option.getOr([])

  let spinner = Ora.make()
  let _ = spinner->Ora.start("configure")

  let opts = Pacote.makeConfig(registryOpts)

  let rootPath = NodePath.resolve([pathToSavedDependencies, sourcePackageName])
  let sourcePackageVersionStr = if sourcePackageVersion !== "" {
    sourcePackageVersion
  } else {
    "latest"
  }
  let sourcePackageSpec = sourcePackageName ++ "@" ++ sourcePackageVersionStr

  let _ = spinner->Ora.succeed(())

  // --- clean previous build ---
  let _ = spinner->Ora.start("clean layer directory")
  await Rimraf.rimraf(pathToLayerData)
  let _ = spinner->Ora.succeed(())

  // --- extract root module ---
  let _ = spinner->Ora.start("extract source package")
  let _ = await RegistryRetry.withRetry(~label="extract " ++ sourcePackageSpec, () =>
    Pacote.extract(sourcePackageSpec, rootPath, opts)
  )
  let _ = spinner->Ora.succeed(())

  // --- post-process root module ---
  switch rootPostProcess {
  | Some(rootFn) =>
    let _ = spinner->Ora.start("postprocess source package")
    Console.log("")
    await rootFn(Obj.magic(0), rootPath)
    let _ = spinner->Ora.succeed(())
  | None => ()
  }

  // --- build dependency tree ---
  let _ = spinner->Ora.start("build dependency tree")
  let arboristConfig = Arborist.makeConfig(
    Dict.fromArray([
      ...registryOpts->Dict.toArray,
      ("path", rootPath),
    ]),
  )
  let tree = await RegistryRetry.withRetry(~label="build dependency tree", () =>
    Arborist.make(arboristConfig)->Arborist.buildIdealTree({
      preferDedupe: true,
      saveType: "prod",
    })
  )
  let _ = spinner->Ora.succeed(())

  // --- stats ---
  let _ = DependencyBundler_Stats.stats(tree, ~shouldPrint=true)

  // --- extract dependencies ---
  let extractionCount = ref(0)
  let _skippedExtractionCount = ref(0)
  let postProcessFailed = ref(false)

  let _ = spinner->Ora.start("extract dependencies")
  let _ = await Treeverse.depth({
    tree,
    visit: async node => {
      spinner->Ora.setSuffixText(node->Arborist.name)

      if node->Arborist.isRoot {
        ()
      } else {
        Console.log2("\nNode: ", node->Arborist.packageName)

        if DependencyBundler_Filter.predIsNecessary(~excludeScopes, ~excludeModules, ~includeModules, ~includeScopes, node) {
          let extractOpts = Pacote.makeConfig(
            Dict.fromArray([
              ...registryOpts->Dict.toArray,
              ("resolved", node->Arborist.resolved),
            ]),
          )
          let dest = NodePath.resolve([pathToSavedDependencies, node->Arborist.packageName])
          let _ = await RegistryRetry.withRetry(
            ~label="extract " ++ node->Arborist.packageName,
            () => Pacote.extract(
              node->Arborist.packageName ++ "@" ++ node->Arborist.version,
              dest,
              extractOpts,
            ),
          )

          spinner->Ora.setSuffixText("")
          let _ = spinner->Ora.succeed(~text="extracted dependency " ++ node->Arborist.name, ())
          extractionCount := extractionCount.contents + 1

          // --- post-processing ---
          let postProcessingNamesForDependencies =
            postProcess
            ->Dict.keysToArray
            ->Array.filter(name => name->String.startsWith(">"))
            ->Array.map(name => name->String.slice(~start=1, ~end=name->String.length))

          let shouldPostProcess = postProcess->Dict.get(node->Arborist.name)->Option.isSome
          let shouldPostProcessDependency = postProcessingNamesForDependencies->Array.length > 0

          if shouldPostProcess || shouldPostProcessDependency {
            let _ = spinner->Ora.start("postprocess " ++ node->Arborist.name)
          }

          if shouldPostProcess {
            switch postProcess->Dict.get(node->Arborist.name) {
            | Some(fn) =>
              if !(await doPostProcessing(node, pathToSavedDependencies, fn, spinner)) {
                postProcessFailed := true
              }
            | None => ()
            }
          }

          for i in 0 to postProcessingNamesForDependencies->Array.length - 1 {
            let depName = postProcessingNamesForDependencies->Array.getUnsafe(i)
            if DependencyBundler_Filter.hasDependency(node, depName) {
              switch postProcess->Dict.get(">" ++ depName) {
              | Some(fn) =>
                if !(await doPostProcessing(node, pathToSavedDependencies, fn, spinner)) {
                  postProcessFailed := true
                }
              | None => ()
              }
            }
          }
        } else {
          _skippedExtractionCount := _skippedExtractionCount.contents + 1
        }
      }
    },
    getChildren: (node, _) =>
      if DependencyBundler_Stats.hasChildren(node) {
        node->Arborist.children->Map.values->Iterator.toArray
      } else {
        []
      },
    filter: node => DependencyBundler_Filter.predIsNecessary(~excludeScopes, ~excludeModules, ~includeModules, ~includeScopes, node),
  })

  spinner->Ora.setSuffixText("")
  let _ = spinner->Ora.succeed(())

  // Fail the whole build if any post-processing step failed — a broken layer must
  // not be zipped and shipped as if it succeeded.
  if postProcessFailed.contents {
    panic("layer build: one or more post-processing steps failed")
  }

  // --- rescript safety check ---
  // Look rescript up from the tree's own children rather than a walk-populated
  // ref: rescript is a dev dep filtered out of the extraction walk, so the ref
  // was always None and this guard could never fire.
  switch tree->Arborist.children->Map.get("rescript") {
  | Some(rescriptNode) =>
    rescriptNode
    ->Arborist.edgesIn
    ->Arborist.setToArray
    ->Array.forEach(rescriptEdge => {
      if rescriptEdge->Arborist.edgeType === "prod" {
        let msg = rescriptEdge->Arborist.edgeName ++ " requires rescript!"
        Console.error(msg)
        panic(msg)
      }
    })
  | None => ()
  }

  // --- zip ---
  let _ = spinner->Ora.start("zip layer to " ++ pathToLayerData)
  await ZipAFolder.zip(pathToLayerData, NodePath.join([pathToLayerData, "../reventless-layer.zip"]))
  let _ = spinner->Ora.succeed(())

  Console.log2("Extracted dependencies:", extractionCount.contents)
}
