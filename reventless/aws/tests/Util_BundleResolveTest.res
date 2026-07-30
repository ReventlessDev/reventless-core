open JestGlobals

@module("fs") external mkdtempSync: string => string = "mkdtempSync"
@module("fs") external mkdirSync: (string, {"recursive": bool}) => unit = "mkdirSync"
@module("fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("fs") external rmSync: (string, {"recursive": bool, "force": bool}) => unit = "rmSync"
@module("fs") external realpathSync: string => string = "realpathSync"
@module("path") external join2: (string, string) => string = "join"
@module("os") external tmpdir: unit => string = "tmpdir"
@val @scope("process") external chdir: string => unit = "chdir"
@val @scope("process") external cwd: unit => string = "cwd"

// A Pulumi project that pins a package the framework does not depend on: the
// shape of a host-shell bundle, which is the platform's deploy input rather
// than one of reventless-aws's own dependencies. realpath because macOS hands
// out /var/... symlinks for tmpdir while require.resolve reports /private/var.
let makeProject = (pkgName: string): (string, string) => {
  let project = realpathSync(mkdtempSync(join2(tmpdir(), "pulumi-project-")))
  let pkgDir = join2(join2(project, "node_modules"), pkgName)
  mkdirSync(pkgDir, {"recursive": true})
  writeFileSync(join2(pkgDir, "package.json"), `{"name":"${pkgName}","version":"9.9.9"}`)
  (project, pkgDir)
}

describe("Util_Bundle.resolvePackageRoot", () => {
  let pkgName = "pinned-by-the-project"
  let (project, pkgDir) = makeProject(pkgName)
  let originalCwd = cwd()
  // The framework fast path: what getModuleSpecifier would have cached from
  // walking reventless-aws's own tree.
  let frameworkRoot = "/resolved/from/the/framework"

  beforeAll(() => {
    chdir(project)
    Util_Bundle.packageRootCache->Dict.set(pkgName, frameworkRoot)
  })

  afterAll(() => {
    chdir(originalCwd)
    rmSync(project, {"recursive": true, "force": true})
  })

  testSync("framework-rooted by default", () =>
    expect(Util_Bundle.resolvePackageRoot(pkgName))->toBe(frameworkRoot)
  )

  // The regression: one cache key meant the framework's answer was handed back
  // for both questions, so a platform pinning a newer host-shell deployed
  // whatever the workspace had hoisted instead.
  testSync("~fromPulumiProject reads the project's own node_modules", () =>
    expect(Util_Bundle.resolvePackageRoot(~fromPulumiProject=true, pkgName))->toBe(pkgDir)
  )

  testSync("the two answers are cached apart, not overwritten", () => {
    let _ = Util_Bundle.resolvePackageRoot(~fromPulumiProject=true, pkgName)
    expect(Util_Bundle.resolvePackageRoot(pkgName))->toBe(frameworkRoot)
  })
})
