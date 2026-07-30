// Entry point for the platform generator.
// Usage: generate-platform <deploy-manifest.yaml>
//
// Reads the deploy manifest for the plugin list, unions the plugins' committed
// `capabilities.json` manifests, and writes the platform's committed
// `PlatformCapabilities.res` (see PlatformCodegen). The platform root stays
// hand-written and reads `PlatformCapabilities.capabilities`.
//
// A plugin path may be the composition package itself (its `src/` carries the
// manifest) or an `-aws` deploy root that delegates to one. The delegation's
// single existing record is the root's own `generate` script —
// `generate-plugin --aws <Namespace> <srcDir>` — so the composition `src/` is
// read from there rather than from a second, hand-typed spelling of the path.

@val external processExit: int => unit = "process.exit"
@module("yaml") external parseYaml: string => JSON.t = "parse"

let fail = (message: string) => {
  Console.error("generate-platform: " ++ message)
  processExit(1)
}

let asObject = (json: JSON.t): option<dict<JSON.t>> => json->JSON.Decode.object
let stringAt = (obj: dict<JSON.t>, field: string): option<string> =>
  obj->Dict.get(field)->Option.flatMap(JSON.Decode.string)

// Where a plugin keeps its capability manifest. The direct arm covers a plugin
// path that is itself a composition package; the delegated arm follows the
// `-aws` root's `generate-plugin --aws <Namespace> <srcDir>` script to the
// composition `src/` it is generated from.
let manifestPathFor = (~pluginDir: string): option<string> => {
  let direct = Generator_Node.join([pluginDir, "src", "capabilities.json"])
  if Generator_Node.existsSync(direct) {
    Some(direct)
  } else {
    let packageJsonPath = Generator_Node.join([pluginDir, "package.json"])
    if !Generator_Node.existsSync(packageJsonPath) {
      None
    } else {
      let generateScript =
        try Generator_Node.readFileSync(packageJsonPath)
        ->JSON.parseOrThrow
        ->asObject
        ->Option.flatMap(pkg => pkg->Dict.get("scripts"))
        ->Option.flatMap(asObject)
        ->Option.flatMap(scripts => scripts->stringAt("generate")) catch {
        | _ => None
        }
      generateScript
      ->Option.flatMap(script => {
        let tokens = script->String.split(" ")->Array.filter(t => t != "")
        switch tokens {
        | ["generate-plugin", "--aws", _namespace, srcDir] =>
          Some(Generator_Node.resolve([pluginDir, srcDir, "capabilities.json"]))
        | _ => None
        }
      })
      ->Option.filter(Generator_Node.existsSync)
    }
  }
}

let () = {
  let manifestArg = Generator_Node.argv->Array.get(2)->Option.getOr("")
  if manifestArg == "" {
    Console.error("Usage: generate-platform <deploy-manifest.yaml>")
    processExit(1)
  } else {
    let manifestPath = Generator_Node.resolve([manifestArg])
    if !Generator_Node.existsSync(manifestPath) {
      fail(`${manifestPath} not found`)
    }
    let manifestDir = Generator_Node.dirname(manifestPath)
    let deployManifest = try Generator_Node.readFileSync(manifestPath)->parseYaml catch {
    | _ => {
        fail(`could not parse ${manifestPath} as YAML`)
        JSON.Null
      }
    }

    let platformPath =
      deployManifest
      ->asObject
      ->Option.flatMap(m => m->Dict.get("platform"))
      ->Option.flatMap(asObject)
      ->Option.flatMap(p => p->stringAt("path"))
    let plugins =
      deployManifest
      ->asObject
      ->Option.flatMap(m => m->Dict.get("plugins"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.map(entries =>
        entries->Array.filterMap(entry => {
          let obj = entry->asObject
          switch (
            obj->Option.flatMap(o => o->stringAt("name")),
            obj->Option.flatMap(o => o->stringAt("path")),
          ) {
          | (Some(name), Some(path)) => Some((name, path))
          | _ => None
          }
        })
      )

    switch (platformPath, plugins) {
    | (Some(platformPath), Some(plugins)) => {
        let pluginManifests = plugins->Array.map(((pluginName, pluginPath)) => {
          let pluginDir = Generator_Node.resolve([manifestDir, pluginPath])
          switch manifestPathFor(~pluginDir) {
          | None => {
              fail(
                `no capabilities.json found for plugin "${pluginName}" (${pluginDir}) — ` ++
                `build the plugin first; its build emits src/capabilities.json beside Plugin.res`,
              )
              ({pluginName, manifest: {capabilities: []}}: PlatformCodegen.pluginManifest)
            }
          | Some(capabilitiesPath) => {
              let manifest = try Generator_Node.readFileSync(capabilitiesPath)
              ->JSON.parseOrThrow
              ->S.parseOrThrow(CapabilityManifest.schema) catch {
              | _ => {
                  fail(`could not parse ${capabilitiesPath} as a capability manifest`)
                  ({capabilities: []}: CapabilityManifest.t)
                }
              }
              ({pluginName, manifest}: PlatformCodegen.pluginManifest)
            }
          }
        })

        switch PlatformCodegen.render(pluginManifests) {
        | Error(message) => fail(message)
        | Ok(source) => {
            let outputPath = Generator_Node.resolve([
              manifestDir,
              platformPath,
              "src",
              "PlatformCapabilities.res",
            ])
            Generator_Node.writeFileSync(outputPath, source)
            Console.log("Generated: " ++ outputPath)
          }
        }
      }
    | _ => fail(`${manifestPath} needs a \`platform.path\` and a \`plugins\` list with name + path`)
    }
  }
}
