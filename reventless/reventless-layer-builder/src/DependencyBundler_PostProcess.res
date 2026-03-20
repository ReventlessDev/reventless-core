type postProcessFn = (Arborist.node, string) => promise<unit>

let rescriptDependent: postProcessFn = async (_node, cwd) => {
  let rmRes = Rimraf.rimrafWithOptions("**/*.res", {glob: {cwd: cwd}})
  let rmResi = Rimraf.rimrafWithOptions("**/*.resi", {glob: {cwd: cwd}})
  let _ = await Promise.all2((rmRes, rmResi))
}

let reventlessCore: postProcessFn = async (_node, cwd) => {
  await Rimraf.rimrafMany([
    NodePath.resolve([cwd, "coverage"]),
    NodePath.resolve([cwd, "scripts"]),
    NodePath.resolve([cwd, "test-helper"]),
    NodePath.resolve([cwd, "tests"]),
  ])
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
