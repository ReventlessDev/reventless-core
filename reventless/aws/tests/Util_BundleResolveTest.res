open JestGlobals

// A Pulumi project that pins a package the framework does not depend on: the
// shape of a host-shell bundle, which is the platform's deploy input rather
// than one of reventless-aws's own dependencies. realpath because macOS hands
// out /var/... symlinks for tmpdir while require.resolve reports /private/var.
let makeProject = (pkgName: string): (string, string) => {
  let project =
    NodeFs.realpathSync(NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "pulumi-project-"])))
  let pkgDir = NodePath.join([NodePath.join([project, "node_modules"]), pkgName])
  NodeFs.mkdirSync(pkgDir, {recursive: true})
  NodeFs.writeFileSync(
    NodePath.join([pkgDir, "package.json"]),
    `{"name":"","version":"9.9.9"}`,
  )
  (project, pkgDir)
}

describe("Util_Bundle.resolvePackageRoot", () => {
  let pkgName = "pinned-by-the-project"
  let (project, pkgDir) = makeProject(pkgName)
  let originalCwd = NodeProcess.cwd()
  // The framework fast path: what getModuleSpecifier would have cached from
  // walking reventless-aws's own tree.
  let frameworkRoot = "/resolved/from/the/framework"

  beforeAll(() => {
    NodeProcess.chdir(project)
    Util_Bundle.packageRootCache->Dict.set(pkgName, frameworkRoot)
  })

  afterAll(() => {
    NodeProcess.chdir(originalCwd)
    NodeFs.rmSync(project, {recursive: true, force: true})
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
