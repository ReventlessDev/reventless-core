open JestGlobals

// Where the harvest finds the local platform it applies a plugin to. A monorepo
// member has its own `node_modules`; an app that installs at its root
// (`node-linker=hoisted`) has the package only there, and the harvest used to look
// in the plugin's folder alone — so on such an app it read no plugin at all and
// derived nothing.

@module("../src/lifecycle/loadPluginStructure.mjs")
external localPlatformPath: string => option<string> = "localPlatformPath"

let platformRel = ["node_modules", "@reventlessdev", "reventless-local", "src"]

let scratch = (): string => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "local-platform-"]))

let installAt = (dir: string): string => {
  let src = NodePath.join([dir, ...platformRel])
  NodeFs.mkdirSync(src, {recursive: true})
  let file = NodePath.join([src, "Platform.res.mjs"])
  NodeFs.writeFileSync(file, "export const Make = () => ({})\n")
  file
}

let pluginIn = (dir: string): string => {
  let plugin = NodePath.join([dir, "charging"])
  NodeFs.mkdirSync(plugin, {recursive: true})
  plugin
}

describe("loadPluginStructure.localPlatformPath", () => {
  testSync("finds the platform in the plugin's own node_modules", () => {
    let app = scratch()
    let plugin = pluginIn(app)
    let file = installAt(plugin)
    expect(localPlatformPath(plugin))->toEqual(Some(file))
  })

  testSync("finds it at the app's root when dependencies are hoisted", () => {
    let app = scratch()
    let plugin = pluginIn(app)
    let file = installAt(app)
    expect(localPlatformPath(plugin))->toEqual(Some(file))
  })

  testSync("prefers the nearer copy", () => {
    let app = scratch()
    let plugin = pluginIn(app)
    let _ = installAt(app)
    let own = installAt(plugin)
    expect(localPlatformPath(plugin))->toEqual(Some(own))
  })

  testSync("says none when no node_modules up the tree has it", () => {
    let plugin = pluginIn(scratch())
    expect(localPlatformPath(plugin))->toEqual(None)
  })
})
