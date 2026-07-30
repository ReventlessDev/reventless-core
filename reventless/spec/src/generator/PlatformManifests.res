// Where a deploy-manifest entry's capability manifests live — and, when it
// contributes none, whether that is because the entry is not a plugin at all.
//
// A deploy manifest enumerates *deployables*, not plugins. An SdkService stack,
// a static SPA, a standalone ingester Lambda are all legitimate entries with no
// `pluginStructure` to derive capabilities from; contributing nothing is the
// right answer for those. A plugin whose manifest is merely unbuilt is the
// opposite case, and silently skipping it would deprovision the stores it
// declared. The two are told apart by evidence — something in the package graph
// that emits a capability manifest — never by falling through the arms below.
//
// Resolution order, first arm that yields manifests wins:
//
//   1. `<dir>/src/capabilities.json` — the entry is itself a composition
//      package, so its manifest sits beside its composition root.
//   2. `<dir>`'s own `generate: generate-plugin --aws <Namespace> <srcDir>`
//      script — an `-aws` root generated from a composition `src/` elsewhere in
//      the same repo. The script is the single existing record of that
//      delegation, so no second hand-typed spelling of the path is introduced.
//   3. `<dir>`'s dependencies — an `-aws` root that *installs* a published
//      composition package, which is the shape the framework recommends and the
//      one arms 1 and 2 both miss. Every plugin dependency contributes: a root
//      deploying two plugins legitimately needs both manifests.
//   4. Nothing in the package graph emits a manifest — not a plugin stack.
//
// I/O goes through `fileSystem` so the arms are testable without a fixture
// tree; `nodeFileSystem` is what the generator passes.

/** How a manifest was found — reported so the resolving arm never has to be
    reconstructed from the output. */
type via =
  | Composition
  | Generated(string)
  | Dependency(string)

type manifest = {path: string, via: via}

/** Why the entry counted as a plugin, and where its manifest was looked for. */
type unbuilt = {evidence: string, expected: string}

type t =
  | Manifests(array<manifest>)
  /** Something here emits a capability manifest, but the manifest is not on
      disk: a plugin that has not been built. */
  | Unbuilt(unbuilt)
  /** No plugin composition anywhere in the entry's package graph. */
  | NotAPlugin

type fileSystem = {
  exists: string => bool,
  readJson: string => option<JSON.t>,
}

let nodeFileSystem: fileSystem = {
  exists: Generator_Node.existsSync,
  readJson: path =>
    try Some(Generator_Node.readFileSync(path)->JSON.parseOrThrow) catch {
    | _ => None
    },
}

let describeVia = (via: via): string =>
  switch via {
  | Composition => "its own src/"
  | Generated(srcDir) => `its \`generate\` script's ${srcDir}`
  | Dependency(name) => `dependency ${name}`
  }

let asObject = (json: JSON.t): option<dict<JSON.t>> => json->JSON.Decode.object

let packageJsonAt = (~fs: fileSystem, ~dir: string): option<dict<JSON.t>> =>
  fs.readJson(Generator_Node.join([dir, "package.json"]))->Option.flatMap(asObject)

let scriptsOf = (pkg: dict<JSON.t>): array<string> =>
  pkg
  ->Dict.get("scripts")
  ->Option.flatMap(asObject)
  ->Option.mapOr([], scripts =>
    scripts->Dict.valuesToArray->Array.filterMap(JSON.Decode.string)
  )

// The composition `src/` an `-aws` root is generated from, read off the script
// that performs the generation.
let generatedSrcDir = (pkg: dict<JSON.t>): option<string> =>
  pkg
  ->Dict.get("scripts")
  ->Option.flatMap(asObject)
  ->Option.flatMap(scripts => scripts->Dict.get("generate"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.flatMap(script => {
    let tokens = script->String.split(" ")->Array.filter(t => t != "")
    switch tokens {
    | ["generate-plugin", "--aws", _namespace, srcDir] => Some(srcDir)
    | _ => None
    }
  })

// A package that runs `emit-capabilities` as part of its build is a plugin
// composition package, whether or not it has been built yet. That is the whole
// signal G1 needs: it is stated once, by the package that owns the fact, and it
// is already there in every plugin package — unlike a `kind:` on the deploy
// manifest, which would restate it a second time.
//
// `reventless-local` *provides* the bin under `bin`, and so is correctly not
// matched here.
let emitsCapabilities = (pkg: dict<JSON.t>): bool =>
  pkg->scriptsOf->Array.some(script => script->String.includes("emit-capabilities"))

let dependencyNames = (pkg: dict<JSON.t>): array<string> => {
  let seen = Dict.make()
  ["dependencies", "devDependencies"]
  ->Array.flatMap(field =>
    pkg->Dict.get(field)->Option.flatMap(asObject)->Option.mapOr([], Dict.keysToArray)
  )
  ->Array.filter(name =>
    switch seen->Dict.get(name) {
    | Some(_) => false
    | None => {
        seen->Dict.set(name, true)
        true
      }
    }
  )
}

/** Node's directory resolution: `<dir>/node_modules/<name>`, then each parent's,
    up to the filesystem root. Walking it rather than binding `require.resolve`
    keeps the lookup on the package directory itself — a package's entry point
    may be anywhere, and it is `src/capabilities.json` that is wanted. */
let resolvePackageDir = (~fs: fileSystem, ~fromDir: string, ~name: string): option<string> => {
  let rec search = dir => {
    let candidate = Generator_Node.join([dir, "node_modules", name])
    if fs.exists(Generator_Node.join([candidate, "package.json"])) {
      Some(candidate)
    } else {
      let parent = Generator_Node.dirname(dir)
      parent == dir ? None : search(parent)
    }
  }
  search(fromDir)
}

// Arm 3. Unbuilt wins over what was found: a root deploying two plugins needs
// both manifests, so one of them missing is a failure even though the other
// resolved.
let fromDependencies = (~fs: fileSystem, ~pluginDir: string, ~pkg: dict<JSON.t>): t => {
  let found = []
  let unbuilt = ref(None)
  pkg
  ->dependencyNames
  ->Array.forEach(name =>
    switch resolvePackageDir(~fs, ~fromDir=pluginDir, ~name) {
    | None => ()
    | Some(packageDir) => {
        let candidate = Generator_Node.join([packageDir, "src", "capabilities.json"])
        if fs.exists(candidate) {
          found->Array.push({path: candidate, via: Dependency(name)})
        } else if packageJsonAt(~fs, ~dir=packageDir)->Option.mapOr(false, emitsCapabilities) {
          switch unbuilt.contents {
          | Some(_) => ()
          | None =>
            unbuilt :=
              Some({
                evidence: `dependency ${name} emits a capability manifest`,
                expected: candidate,
              })
          }
        }
      }
    }
  )
  switch (unbuilt.contents, found) {
  | (Some({evidence, expected}), _) => Unbuilt({evidence, expected})
  | (None, []) => NotAPlugin
  | (None, manifests) => Manifests(manifests)
  }
}

let resolve = (~fs: fileSystem=nodeFileSystem, ~pluginDir: string): t => {
  let direct = Generator_Node.join([pluginDir, "src", "capabilities.json"])
  if fs.exists(direct) {
    Manifests([{path: direct, via: Composition}])
  } else {
    switch packageJsonAt(~fs, ~dir=pluginDir) {
    | None => NotAPlugin
    | Some(pkg) =>
      switch generatedSrcDir(pkg) {
      | Some(srcDir) => {
          let expected = Generator_Node.resolve([pluginDir, srcDir, "capabilities.json"])
          if fs.exists(expected) {
            Manifests([{path: expected, via: Generated(srcDir)}])
          } else {
            Unbuilt({
              evidence: `its \`generate\` script composes ${srcDir}`,
              expected,
            })
          }
        }
      | None => fromDependencies(~fs, ~pluginDir, ~pkg)
      }
    }
  }
}
