// Derive a trait's listing metadata from the trait itself.
//
// Usage: trait-manifest <trait-package> --out <file>
//
// The old design had a hand-written `trait.yaml`. Everything in it is already a
// fact somewhere typed, so this reads those facts instead: identity from the
// package, needs from the value the trait exports, and the config surface from
// the emitter's own sury schema.
//
// Nothing here knows a trait's vocabulary. Both modules are resolved by the name
// the trait is given and dynamically imported, exactly as `graft-trait` reaches a
// scaffold — so `reventless-spec` still depends on no trait.

@val external dynImport: string => promise<'a> = "import"

type scaffoldExports = {configSchema: S.t<unknown>}
type traitExports = {capabilityNeeds: array<CapabilityNeed.t>}

let fail = (message: string) => {
  Console.error("trait-manifest: " ++ message)
  NodeProcess.exit(1)
}

let usage = `Usage: trait-manifest <trait-package> --out <file>

  <trait-package>  the installed trait, e.g. @reventlessdev/trait-attachments
  --out            where to write the manifest

  Everything is read from the trait: identity from its package.json, capability
  needs from the value it exports, the config surface from its emitter's schema.
  There is nothing to hand-write and nothing to keep in step.`

/** `@scope/trait-address-geocoding` → `AddressGeocoding`. The same derivation
    `graft-trait` and `certify-trait` do, for the same reason: a trait's module
    names follow from its package name, so nothing has to be configured. */
let moduleBase = (traitPackage: string) =>
  traitPackage
  ->String.split("/")
  ->Array.last
  ->Option.getOr("")
  ->String.replace("trait-", "")
  ->String.split("-")
  ->Array.map(part =>
    part->String.charAt(0)->String.toUpperCase ++
      part->String.slice(~start=1, ~end=part->String.length)
  )
  ->Array.join("")

let resolveFrom = (specifier: string) =>
  try Some(
    NodeModule.createRequire(NodeProcess.cwd() ++ "/index.js")->NodeModule.requireResolve(specifier),
  ) catch {
  | _ => None
  }

let readPackageField = (packageJson: JSON.t, field: string, fallback: string) =>
  packageJson
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get(field))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr(fallback)

let main = async () => {
  let argv = NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)
  let flag = key =>
    switch argv->Array.indexOf("--" ++ key) {
    | -1 => None
    | i => argv->Array.get(i + 1)
    }

  switch (argv->Array.get(0), flag("out")) {
  | (None, _) | (Some(""), _) | (Some("--help"), _) | (Some("-h"), _) => {
      Console.log(usage)
      NodeProcess.exit(argv->Array.length == 0 ? 1 : 0)
    }
  | (Some(_), None) => fail("--out is required.\n\n" ++ usage)
  | (Some(traitPackage), Some(out)) => {
      let base = moduleBase(traitPackage)

      let packageJson = switch resolveFrom(`${traitPackage}/package.json`) {
      | None =>
        fail(
          `${traitPackage} is not installed here. A manifest is derived from the trait, so ` ++
          `the trait has to be resolvable.`,
        )
        JSON.Encode.null
      | Some(path) => NodeFs.readFileSync(path)->JSON.parseOrThrow
      }

      // The trait's entry module, for what it needs. Absent is refused rather
      // than defaulted to `[]`: "needs nothing" and "nobody said" are different
      // claims, and a listing that could not tell them apart would quietly
      // publish the second as the first.
      let traitModule: traitExports = switch resolveFrom(`${traitPackage}/src/${base}.res.mjs`) {
      | None =>
        fail(
          `${traitPackage} exports no ${base} module, so its capability needs cannot be read.\n` ++
          `  A trait states them as a value — an empty array if it brokers nothing — because ` ++
          `an unstated need fails silently at run time.`,
        )
        %raw(`undefined`)
      | Some(path) => await dynImport(NodeUrl.pathToFileURL(path)["href"])
      }

      // The emitter is optional: a trait whose graft is all patches has nothing
      // to write, and says so here rather than by failing when someone tries.
      let scaffold: option<scaffoldExports> = switch resolveFrom(
        `${traitPackage}/src/${base}_Scaffold.res.mjs`,
      ) {
      | None => None
      | Some(path) => Some(await dynImport(NodeUrl.pathToFileURL(path)["href"]))
      }

      let manifest: TraitManifest.t = {
        trait: readPackageField(packageJson, "name", traitPackage),
        version: readPackageField(packageJson, "version", "0.0.0"),
        description: readPackageField(packageJson, "description", ""),
        license: readPackageField(packageJson, "license", ""),
        capabilities: traitModule.capabilityNeeds->Array.map(CapabilityNeed.toString),
        config: switch scaffold {
        | Some({configSchema}) => TraitManifest.configFieldsOf(configSchema)
        | None => []
        },
        scaffolded: scaffold->Option.isSome,
      }

      NodeFs.writeFileSync(out, manifest->TraitManifest.render)
      Console.log(
        `trait-manifest: ${manifest.trait}@${manifest.version} — ` ++
        `${(manifest.capabilities->Array.length)->Int.toString} capabilit(ies), ` ++
        `${(manifest.config->Array.length)->Int.toString} config field(s)`,
      )
      Console.log(`Wrote: ${out}`)
    }
  }
}

main()->Promise.ignore
