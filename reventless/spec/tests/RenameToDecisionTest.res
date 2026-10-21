open JestGlobals

module R = RenameToDecision

describe("RenameToDecision.rewrite", () => {
  testSync("the attribute, with and without a spec name", () =>
    expect(R.rewrite("@@reventless.behavior\n@@reventless.behavior(Product)\n"))->toBe(
      "@@reventless.decision\n@@reventless.decision(Product)\n",
    )
  )

  testSync("the GWT DSL, its module types, the module type and the adapter", () =>
    expect(
      R.rewrite(
        "include ReventlessGwt.Behavior_GWT.MakeFromAggregate(Order, Order_Behavior)\n" ++
        "module Spec: ReventlessGwt.Behavior_GWT.BehaviorSpec\n" ++
        "module B: ReventlessGwt.Behavior_GWT.Behavior with module Spec = Spec\n" ++
        "module A: Reventless.Behavior.T with module Spec = Spec\n" ++
        "module S: Reventless.StateChangeSlice.Behavior with module Spec := Spec\n" ++ "module O = ReventlessGwt.Mapping_GWT.FromBehavior(Order, Order_Behavior)\n",
      ),
    )->toBe(
      "include ReventlessGwt.Decision_GWT.MakeFromAggregate(Order, Order_Decision)\n" ++
      "module Spec: ReventlessGwt.Decision_GWT.DecisionSpec\n" ++
      "module B: ReventlessGwt.Decision_GWT.Decision with module Spec = Spec\n" ++
      "module A: Reventless.Decision.T with module Spec = Spec\n" ++
      "module S: Reventless.StateChangeSlice.Decision with module Spec := Spec\n" ++ "module O = ReventlessGwt.Mapping_GWT.FromDecision(Order, Order_Decision)\n",
    )
  )

  testSync("the access step, but not the input step that shares its prefix", () =>
    expect(R.rewrite("->thenRefused\n->thenRefusedInput(\"title\")\n"))->toBe(
      "->thenForbidden\n->thenRefusedInput(\"title\")\n",
    )
  )

  testSync("a trait's conformance binding and its uses in the same file", () =>
    expect(
      R.rewrite(
        "module Host = {\n  module Behavior = Customer_Behavior\n}\nlet c = Behavior.channelOf(x)\n",
      ),
    )->toBe(
      "module Host = {\n  module Decision = Customer_Decision\n}\nlet c = Decision.channelOf(x)\n",
    )
  )

  testSync("plain English and look-alike names are left alone", () => {
    let prose = "// the runtime's behavior; orderedCacheBehaviors; ProductBehavior; X_BehaviorLog\n"
    expect(R.rewrite(prose))->toBe(prose)
  })
})

describe("RenameToDecision.parseArgs", () => {
  testSync("defaults to the current directory", () =>
    expect(R.parseArgs([]))->toEqual(Ok({R.dir: ".", dryRun: false}))
  )

  testSync("a directory and --dry-run", () =>
    expect(R.parseArgs(["--dry-run", "src"]))->toEqual(Ok({R.dir: "src", dryRun: true}))
  )

  testPromise("a usage mistake exits 2", async () => {
    let observed = await CliArgs.observe(R.cli, ["--force"])
    expect((observed.exitCode, observed.reachedMain))->toEqual((Some(2), false))
  })

  testPromise("--help exits 0", async () => {
    let observed = await CliArgs.observe(R.cli, ["--help"])
    expect(observed.exitCode)->toEqual(Some(0))
  })
})

// ── A fixture tree ───────────────────────────────────────────────────────────

let write = (root, path, contents) => {
  let full = NodePath.join([root, path])
  NodeFs.mkdirSync(NodePath.dirname(full), {recursive: true})
  NodeFs.writeFileSync(full, contents)
}

let rec listFiles = (root, dir, acc) =>
  NodeFs.readdirSync(NodePath.join([root, dir]), {withFileTypes: true})->Array.forEach(entry => {
    let rel = dir == "" ? entry->NodeFs.direntName : dir ++ "/" ++ entry->NodeFs.direntName
    if entry->NodeFs.isDirectory {
      if entry->NodeFs.direntName != ".git" {
        listFiles(root, rel, acc)
      }
    } else {
      acc->Array.push((rel, NodeFs.readFileSync(NodePath.join([root, rel]))))
    }
  })

let tree = root => {
  let acc = []
  listFiles(root, "", acc)
  acc->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
}

let before = [
  ("src/Product/Aggregate/Product.res", "@@reventless.spec\n"),
  (
    "src/Product/Aggregate/Product_Behavior.res",
    "// Product aggregate behavior.\n@@reventless.behavior\nlet initialState = 0\n",
  ),
  ("src/Product/Aggregate/Product_Behavior.res.mjs", "export {}\n"),
  ("src/Order/StateChange/PlaceOrder_Behavior.res", "@@reventless.behavior(PlaceOrder)\n"),
  (
    "tests/Order/StateChange/PlaceOrder_GWT.res",
    "@@reventless.gwt(PlaceOrder, PlaceOrder_Behavior)\nlet t = x->thenRefused\n",
  ),
  ("src/plugin.json", "{\"name\": \"Shop\"}\n"),
  ("node_modules/dep/src/Dep_Behavior.res", "@@reventless.behavior\n"),
  ("lib/bs/src/Product_Behavior.res", "@@reventless.behavior\n"),
]

let after = [
  ("lib/bs/src/Product_Behavior.res", "@@reventless.behavior\n"),
  ("node_modules/dep/src/Dep_Behavior.res", "@@reventless.behavior\n"),
  ("src/Order/StateChange/PlaceOrder_Decision.res", "@@reventless.decision(PlaceOrder)\n"),
  ("src/Product/Aggregate/Product.res", "@@reventless.spec\n"),
  (
    "src/Product/Aggregate/Product_Decision.res",
    "// Product aggregate behavior.\n@@reventless.decision\nlet initialState = 0\n",
  ),
  ("src/Product/Aggregate/Product_Decision.res.mjs", "export {}\n"),
  ("src/plugin.json", "{\"name\": \"Shop\"}\n"),
  (
    "tests/Order/StateChange/PlaceOrder_GWT.res",
    "@@reventless.gwt(PlaceOrder, PlaceOrder_Decision)\nlet t = x->thenForbidden\n",
  ),
]

let fixture = () => {
  let root = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "rename-to-decision-"]))
  before->Array.forEach(((path, contents)) => write(root, path, contents))
  root
}

let gitIn = (root, args) =>
  NodeChildProcess.execFileSync("git", args, {cwd: root, encoding: "utf8"})->String.trim

describe("RenameToDecision.execute", () => {
  testSync("renames the tree outside a git work tree", () => {
    let root = fixture()
    let result = R.execute({dir: root, dryRun: false})
    let renamed = tree(root)
    NodeFs.rmSync(root, {recursive: true, force: true})
    expect((result->Result.isOk, renamed))->toEqual((true, after))
  })

  testSync("--dry-run reports and changes nothing", () => {
    let root = fixture()
    let result = R.execute({dir: root, dryRun: true})
    let untouched = tree(root)
    NodeFs.rmSync(root, {recursive: true, force: true})
    let lines = result->Result.getOr([])
    expect((
      untouched->Array.length,
      lines->Array.some(line => line->String.startsWith("would move")),
      lines->Array.last,
    ))->toEqual((before->Array.length, true, Some("Would rename 2 file(s) and edit 3.")))
  })

  testSync("moves tracked files with git mv inside a work tree", () => {
    let root = fixture()
    let _: string = gitIn(root, ["init", "-q"])
    let _: string = gitIn(root, ["add", "src", "tests"])
    let _: string = gitIn(
      root,
      ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture"],
    )
    let result = R.execute({dir: root, dryRun: false})
    let status = gitIn(root, ["status", "--porcelain"])
    NodeFs.rmSync(root, {recursive: true, force: true})
    expect((
      result->Result.isOk,
      status->String.includes(
        "src/Product/Aggregate/Product_Behavior.res -> src/Product/Aggregate/Product_Decision.res",
      ),
    ))->toEqual((true, true))
  })

  testSync("a target that already exists fails the run and changes nothing", () => {
    let root = fixture()
    write(root, "src/Product/Aggregate/Product_Decision.res", "@@reventless.decision\n")
    let result = R.execute({dir: root, dryRun: false})
    let behaviorFileKept =
      NodePath.join([root, "src/Product/Aggregate/Product_Behavior.res"])->NodeFs.existsSync
    NodeFs.rmSync(root, {recursive: true, force: true})
    expect((result->Result.isError, behaviorFileKept))->toEqual((true, true))
  })

  testSync("a directory that does not exist fails the run", () =>
    expect(R.execute({dir: "/no/such/dir", dryRun: false})->Result.isError)->toBe(true)
  )
})
