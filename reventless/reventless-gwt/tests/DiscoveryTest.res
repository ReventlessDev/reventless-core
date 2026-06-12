// Unit test for the `.gwtignore` subtree prune in `Discovery.discover`. Builds a
// throwaway tree under the OS temp dir: a `keep/` directory with a GWT test, and
// a `skip/` directory carrying a `.gwtignore` sentinel alongside its own GWT
// test. Discovery must return the former and prune the latter — the guarantee
// the codegen golden fixtures rely on (they ship compiled `*_GWT.res.mjs` on
// disk that must never surface as live tests).

open JestGlobals

@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:path") external join: (string, string) => string = "join"

type mkdirOpts = {recursive: bool}
@module("node:fs/promises") external mkdir: (string, mkdirOpts) => promise<Nullable.t<string>> = "mkdir"
@module("node:fs/promises") external writeFile: (string, string) => promise<unit> = "writeFile"

type rmOpts = {recursive: bool, force: bool}
@module("node:fs/promises") external rm: (string, rmOpts) => promise<unit> = "rm"

let endsWith = (paths: array<string>, suffix: string) =>
  paths->Array.some(p => String.endsWith(p, suffix))

describe("Discovery .gwtignore prune", () => {
  testPromise("keeps sibling GWT tests but prunes a subtree carrying .gwtignore", async () => {
    let root = join(tmpdir(), "reventless-gwt-gwtignore-test")
    let _ = await rm(root, {recursive: true, force: true})
    let keep = join(root, "keep")
    let skip = join(root, "skip")
    let _ = await mkdir(keep, {recursive: true})
    let _ = await mkdir(skip, {recursive: true})
    let _ = await writeFile(join(keep, "Keep_GWT.res.mjs"), "")
    let _ = await writeFile(join(skip, "Skip_GWT.res.mjs"), "")
    let _ = await writeFile(join(skip, ".gwtignore"), "")

    let found = await Discovery.discover([root])

    expect(found->endsWith("keep/Keep_GWT.res.mjs"))->toBe(true)
    expect(found->endsWith("skip/Skip_GWT.res.mjs"))->toBe(false)

    let _ = await rm(root, {recursive: true, force: true})
  })
})
