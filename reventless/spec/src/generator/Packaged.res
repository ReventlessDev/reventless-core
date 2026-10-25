// Slices a plugin composes from an installed package, listed in plugin.json's
// `slicesFrom`. The package's `src/` is scanned as the plugin's own is, and each
// module is aliased at the top of the generated Plugin.res, so the rest of the
// composition reads the bare names it reads for the plugin's own files and the
// compiler checks every one.

/** The kinds a package may provide. A plugin is per app and a package is not,
    so only the slices travel: an aggregate, a read model, a task or an extension
    point carries the app's own shape. */
let isSliceKind = (kind: Discovery.componentType) =>
  switch kind {
  | StateChangeSlice
  | StateViewSlice
  | StateViewSliceStream
  | AutomationSlice
  | InboundTranslationSlice
  | OutboundTranslationSlice => true
  | Aggregate | ReadModel | ReadModelStream | Task | ExtensionPoint | Extension => false
  }

/** The package's directory, found the way Node finds it: in the nearest
    `node_modules` from the plugin upwards. */
let locate = (~pluginDir: string, package: string): option<string> => {
  let rec up = dir => {
    let candidate = NodePath.join([dir, "node_modules", package])
    if NodePath.join([candidate, "package.json"])->NodeFs.existsSync {
      Some(candidate)
    } else {
      let parent = NodePath.dirname(dir)
      parent == dir ? None : up(parent)
    }
  }
  up(pluginDir)
}

/** The namespace the package's modules are reached by. Only a namespace written
    out is accepted: the aliases name it, and a derived one is a second spelling
    of the same rule to keep in step with the compiler's. */
let namespaceOf = (~packageDir: string, package: string): string => {
  let rescriptJson = NodePath.join([packageDir, "rescript.json"])
  switch Config.readJson(rescriptJson)->Option.flatMap(j => Config.getStrField(j, "namespace")) {
  | Some(namespace) if namespace != "" => namespace
  | _ =>
    JsError.throwWithMessage(
      `Generator: ${package} lists no namespace in its rescript.json. A package that provides slices names one, as "namespace": "<Name>", so a plugin can reach its modules.`,
    )
  }
}

/** One listed package, located and scanned. */
type source = {
  origin: Discovery.origin,
  with_?: string,
  files: array<Discovery.discoveredFile>,
  identities: array<string>,
}

let scan = (~pluginDir: string, ~exclude: array<string>, entry: Config.sliceSource): source => {
  let {package} = entry
  let packageDir = switch locate(~pluginDir, package) {
  | Some(dir) => dir
  | None =>
    JsError.throwWithMessage(
      `Generator: plugin.json lists slices from ${package}, which is not installed. Add it to the plugin's dependencies and to rescript.json's.`,
    )
  }
  let origin: Discovery.origin = {
    package,
    namespace: namespaceOf(~packageDir, package),
    srcDir: NodePath.join([packageDir, "src"]),
  }
  let files = Discovery.scan(~srcDir=origin.srcDir, ~exclude)->Array.map(d => {...d, origin})
  switch files->Array.find(d => !isSliceKind(d.componentType)) {
  | Some({relPath}) =>
    JsError.throwWithMessage(
      `Generator: ${package} provides ${relPath}, which is not a slice. A package provides slices only; the rest of a plugin is the app's.`,
    )
  | None => ()
  }
  if files->Array.length == 0 {
    JsError.throwWithMessage(
      `Generator: plugin.json lists slices from ${package}, which provides none.`,
    )
  }
  {
    origin,
    with_: ?entry.with_,
    files,
    identities: Discovery.scanIdentities(~srcDir=origin.srcDir, ~exclude),
  }
}

/** Whether a body file is a functor over the app's declaration: it opens with
    `module Make = (`. */
let isFunctorBody = (path: string): bool =>
  path
  ->NodeFs.readFileSync
  ->String.split("\n")
  ->Array.some(line => line->String.startsWith("module Make = ("))

/**
The alias lines for every listed package: one per module the composition names,
in a stable order. A functor-shaped body is applied to the module `with` names,
and one with no `with` to apply it to is refused naming the file.
*/
let aliases = (sources: array<source>): array<string> =>
  sources->Array.flatMap(({origin, ?with_, files, identities}) => {
    let alias = stem => `module ${stem} = ${origin.namespace}.${stem}`
    let modules =
      files
      ->Array.map(d => {
        let path = d->Discovery.pathOf(~srcDir=origin.srcDir)
        if isFunctorBody(path) {
          switch with_ {
          | Some(declaration) => `${alias(d.stem)}.Make(${declaration})`
          | None =>
            JsError.throwWithMessage(
              `Generator: ${origin.package}'s ${d.relPath} is applied to the app's declaration, but plugin.json's entry for it says no "with": name the module to apply it to.`,
            )
          }
        } else {
          alias(d.stem)
        }
      })
      ->Array.concat(identities->Array.map(alias))
      ->Array.toSorted(String.compare)
    Array.concat([`// Slices from ${origin.package}`], modules)
  })
