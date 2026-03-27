type postProcessFn = (Arborist.node, string) => promise<unit>

let rescriptDependent: postProcessFn = async (_node, cwd) => {
  let rmRes = Rimraf.rimrafWithOptions("**/*.res", {glob: {cwd: cwd}})
  let rmResi = Rimraf.rimrafWithOptions("**/*.resi", {glob: {cwd: cwd}})
  let _ = await Promise.all2((rmRes, rmResi))
}

let reventlessCoreDeploytime: postProcessFn = async (_node, cwd) => {
  // Delete test/dev directories
  let rmDirs = Rimraf.rimrafMany([
    NodePath.resolve([cwd, "coverage"]),
    NodePath.resolve([cwd, "scripts"]),
    NodePath.resolve([cwd, "test-helper"]),
    NodePath.resolve([cwd, "tests"]),
  ])
  // Delete deploy-time-only compiled modules (*_Builder, *_Adapter, Pulumi utils, Cloner, etc.)
  // These are never imported by any Lambda entry point — only used at pulumi up time.
  let rmBuilders = Rimraf.rimrafWithOptions("**/*_Builder*.res.mjs", {glob: {cwd: cwd}})
  let rmAdapters = Rimraf.rimrafWithOptions("**/*_Adapter*.res.mjs", {glob: {cwd: cwd}})
  let rmDeploytime = Rimraf.rimrafMany([
    // Deploy-time utilities that import Pulumi
    NodePath.resolve([cwd, "src", "util", "Util_Pulumi.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "Util_Adapter.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "OutputLogger.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "OutputFailsafeDeploytime.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "Util_StackRefs.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "Interstack.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "ResourceQuery.res.mjs"]),
    // Cloner/FTP/CSV — run on Fargate, not Lambda
    NodePath.resolve([cwd, "src", "components", "Cloner.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "CsvStream.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "CSV.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "FTP.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "FTPHandler.res.mjs"]),
    NodePath.resolve([cwd, "src", "util", "Hash.res.mjs"]),
    // Deploy-time admin (Platform_Admin uses Builders + Pulumi)
    NodePath.resolve([cwd, "src", "admin", "Platform_Admin.res.mjs"]),
    // Deploy-time adapter
    NodePath.resolve([cwd, "src", "adapter", "Adapter.res.mjs"]),
    NodePath.resolve([cwd, "src", "adapter", "AdapterDeploytime.res.mjs"]),
  ])
  let _ = await Promise.all3((rmDirs, rmBuilders, rmAdapters))
  let _ = await rmDeploytime
}

let reventlessAwsDeploytime: postProcessFn = async (_node, cwd) => {
  // Delete deploy-time Runtime Builders and RuntimeEnvironment (Pulumi infrastructure code)
  // Entry points (*EntryPoint.mjs) and HandlerFactoryHelpers.mjs must be kept — they are the Lambda handlers.
  let runtimeDir = NodePath.resolve([cwd, "src", "adapter", "Runtime"])
  let rmBuilders = Rimraf.rimrafWithOptions(
    NodePath.resolve([runtimeDir, "*Runtime_Builder*"]),
    {glob: {cwd: runtimeDir}},
  )
  let rmEnv = Rimraf.rimrafWithOptions(
    NodePath.resolve([runtimeDir, "RuntimeEnvironment*"]),
    {glob: {cwd: runtimeDir}},
  )
  let _ = await Promise.all2((rmBuilders, rmEnv))
}

let deleteTests: postProcessFn = async (_node, cwd) => {
  await Rimraf.rimraf(NodePath.resolve([cwd, "tests"]))
}

let deleteEffectSrc: postProcessFn = async (_node, cwd) => {
  await Rimraf.rimraf(NodePath.resolve([cwd, "src"]))
}

let deleteTestsAndExamples: postProcessFn = async (_node, cwd) => {
  await Rimraf.rimrafMany([
    NodePath.resolve([cwd, "tests"]),
    NodePath.resolve([cwd, "test"]),
    NodePath.resolve([cwd, "examples"]),
    NodePath.resolve([cwd, "benchmark"]),
    NodePath.resolve([cwd, "docs"]),
  ])
}

let deleteLodashExtras: postProcessFn = async (_node, cwd) => {
  await Rimraf.rimrafMany([
    NodePath.resolve([cwd, "core.min.js"]),
    NodePath.resolve([cwd, "lodash.min.js"]),
    NodePath.resolve([cwd, "fp"]),
  ])
}
