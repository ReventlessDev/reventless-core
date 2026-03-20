let doPostProcessing = async (node, pathToSavedDependencies, fn, spinner) => {
  let cwd = NodePath.resolve([pathToSavedDependencies, "../" ++ node->Arborist.location])
  let fnName = %raw(`fn.name`)
  let _ = spinner->Ora.start("postprocess " ++ node->Arborist.name ++ ": " ++ fnName)
  Console.log("")
  try {
    await fn(node, cwd)
    let _ = spinner->Ora.succeed(())
  } catch {
  | exn => {
      let _ = spinner->Ora.fail(())
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      Console.error2("postprocessing of " ++ node->Arborist.name ++ " did fail at '" ++ fnName ++ "':", msg)
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
    postProcess,
    registryOpts,
  } = config

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
  let _ = await Pacote.extract(sourcePackageSpec, rootPath, opts)
  let _ = spinner->Ora.succeed(())

  // --- build dependency tree ---
  let _ = spinner->Ora.start("build dependency tree")
  let arboristConfig = Arborist.makeConfig(
    Dict.fromArray([
      ...registryOpts->Dict.toArray,
      ("path", rootPath),
    ]),
  )
  let tree = await Arborist.make(arboristConfig)->Arborist.buildIdealTree({
    preferDedupe: true,
    saveType: "prod",
  })
  let _ = spinner->Ora.succeed(())

  // --- stats ---
  let _ = DependencyBundler_Stats.stats(tree, ~shouldPrint=true)

  // --- extract dependencies ---
  let extractionCount = ref(0)
  let _skippedExtractionCount = ref(0)
  let rescriptModule: ref<option<Arborist.node>> = ref(None)

  let _ = spinner->Ora.start("extract dependencies")
  let _ = await Treeverse.depth({
    tree,
    visit: async node => {
      spinner->Ora.setSuffixText(node->Arborist.name)

      if node->Arborist.isRoot {
        ()
      } else {
        if node->Arborist.name === "rescript" {
          rescriptModule := Some(node)
        }

        Console.log2("\nNode: ", node->Arborist.packageName)

        if DependencyBundler_Filter.predIsNecessary(~excludeScopes, ~excludeModules, node) {
          let extractOpts = Pacote.makeConfig(
            Dict.fromArray([
              ...registryOpts->Dict.toArray,
              ("resolved", node->Arborist.resolved),
            ]),
          )
          let dest = NodePath.resolve([pathToSavedDependencies, node->Arborist.packageName])
          let _ = await Pacote.extract(
            node->Arborist.packageName ++ "@" ++ node->Arborist.version,
            dest,
            extractOpts,
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
            | Some(fn) => await doPostProcessing(node, pathToSavedDependencies, fn, spinner)
            | None => ()
            }
          }

          for i in 0 to postProcessingNamesForDependencies->Array.length - 1 {
            let depName = postProcessingNamesForDependencies->Array.getUnsafe(i)
            if DependencyBundler_Filter.hasDependency(node, depName) {
              switch postProcess->Dict.get(">" ++ depName) {
              | Some(fn) => await doPostProcessing(node, pathToSavedDependencies, fn, spinner)
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
    filter: node => DependencyBundler_Filter.predIsNecessary(~excludeScopes, ~excludeModules, node),
  })

  spinner->Ora.setSuffixText("")
  let _ = spinner->Ora.succeed(())

  // --- rescript safety check ---
  switch rescriptModule.contents {
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
