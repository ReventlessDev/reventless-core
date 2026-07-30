// Entry point for the platform generator.
// Usage: generate-platform <deploy-manifest.yaml>
//
// Reads the deploy manifest for the plugin list, unions the plugins' committed
// `capabilities.json` manifests, and writes the platform's committed
// `PlatformCapabilities.res` (see PlatformCodegen). The platform root stays
// hand-written and reads `PlatformCapabilities.capabilities`.
//
// A deploy manifest enumerates *deployables*, not plugins, and a plugin's
// manifest can sit in any of three places. `PlatformManifests` owns both facts —
// its head comment states the resolution order and why each arm exists; add a
// fourth arm there, not here.

@val external processExit: int => unit = "process.exit"
@module("yaml") external parseYaml: string => JSON.t = "parse"

let fail = (message: string) => {
  Console.error("generate-platform: " ++ message)
  processExit(1)
}

let asObject = (json: JSON.t): option<dict<JSON.t>> => json->JSON.Decode.object
let stringAt = (obj: dict<JSON.t>, field: string): option<string> =>
  obj->Dict.get(field)->Option.flatMap(JSON.Decode.string)

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
        let pluginManifests = plugins->Array.flatMap(((pluginName, pluginPath)) => {
          let pluginDir = Generator_Node.resolve([manifestDir, pluginPath])
          if !Generator_Node.existsSync(pluginDir) {
            fail(`plugin "${pluginName}" points at ${pluginDir}, which does not exist`)
          }
          switch PlatformManifests.resolve(~pluginDir) {
          // A stack whose package graph holds no plugin composition — an
          // SdkService, an SPA, a standalone Lambda — has no capabilities to
          // contribute, which is not an error. Said out loud so a plugin
          // skipped by mistake is visible in the generator's output.
          | NotAPlugin => {
              Console.log(`Skipped: ${pluginName} (${pluginDir}) — no plugin composition`)
              []
            }
          | Unbuilt({evidence, expected}) => {
              fail(
                `no capabilities.json found for plugin "${pluginName}" (${pluginDir}) — ` ++
                `build the plugin first; its build emits src/capabilities.json beside Plugin.res ` ++
                `(${evidence}; expected ${expected})`,
              )
              []
            }
          | Manifests(manifests) =>
            manifests->Array.map(({path, via}) => {
              Console.log(
                `Read: ${pluginName} — ${path} (via ${PlatformManifests.describeVia(via)})`,
              )
              let manifest = try Generator_Node.readFileSync(path)
              ->JSON.parseOrThrow
              ->S.parseOrThrow(CapabilityManifest.schema) catch {
              | _ => {
                  fail(`could not parse ${path} as a capability manifest`)
                  ({capabilities: []}: CapabilityManifest.t)
                }
              }
              ({pluginName, manifest}: PlatformCodegen.pluginManifest)
            })
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
