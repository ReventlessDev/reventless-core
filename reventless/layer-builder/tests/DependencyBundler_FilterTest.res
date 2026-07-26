// First in-package tests for reventless-layer-builder (previously zero). Covers
// `DependencyBundler_Filter` — the exclusion classification that decides which
// installed dependencies are stripped from the Lambda layer. The A9 work made
// the build fail-closed on a post-process error; this pins the upstream
// necessity logic that feeds it. `Arborist` node accessors are plain `@get`
// property reads, so mock nodes are ordinary JS objects.

open JestGlobals

module F = DependencyBundler_Filter

// Minimal mock of an Arborist node — only the fields the Filter predicates read.
let node = (
  ~name,
  ~dev=false,
  ~optional=false,
  ~devOptional=false,
  ~peer=false,
  ~deps=[],
): Arborist.node => {
  let edgesOut = Map.make()
  deps->Array.forEach(d => edgesOut->Map.set(d, Obj.magic(0)))
  {
    "name": name,
    "dev": dev,
    "optional": optional,
    "devOptional": devOptional,
    "peer": peer,
    "edgesOut": edgesOut,
  }->Obj.magic
}

describe("DependencyBundler_Filter.isNodeScopeExcluded", () => {
  testSync("matches a node whose name is under an excluded scope", () =>
    expect(F.isNodeScopeExcluded(["types"], node(~name="@types/node")))->toEqual(true)
  )
  testSync("does not match a node outside the excluded scopes", () =>
    expect(F.isNodeScopeExcluded(["types"], node(~name="@reventlessdev/reventless-spec")))->toEqual(
      false,
    )
  )
  testSync("does not match an unscoped node", () =>
    expect(F.isNodeScopeExcluded(["types"], node(~name="lodash")))->toEqual(false)
  )
})

describe("DependencyBundler_Filter.isNodeExcluded", () => {
  testSync("matches a node named in the exclude list", () =>
    expect(F.isNodeExcluded(["aws-sdk"], node(~name="aws-sdk")))->toEqual(true)
  )
  testSync("does not match a node absent from the exclude list", () =>
    expect(F.isNodeExcluded(["aws-sdk"], node(~name="lodash")))->toEqual(false)
  )
})

describe("DependencyBundler_Filter.hasDependency", () => {
  testSync("true when the node has an outgoing edge with that key", () =>
    expect(F.hasDependency(node(~name="pkg", ~deps=["rescript", "sury"]), "rescript"))->toEqual(true)
  )
  testSync("false when the node lacks that dependency", () =>
    expect(F.hasDependency(node(~name="pkg", ~deps=["sury"]), "rescript"))->toEqual(false)
  )
  testSync("hasRescriptDependency is the rescript-keyed specialisation", () =>
    expect(F.hasRescriptDependency(node(~name="pkg", ~deps=["rescript"])))->toEqual(true)
  )
})

describe("DependencyBundler_Filter.isNodeScopeIncluded", () => {
  testSync("matches a node under an included scope", () =>
    expect(F.isNodeScopeIncluded(["smithy"], node(~name="@smithy/middleware-endpoint")))->toEqual(
      true,
    )
  )
  testSync("does not match a node outside the included scopes", () =>
    expect(F.isNodeScopeIncluded(["smithy"], node(~name="@aws-sdk/client-s3")))->toEqual(false)
  )
})

describe("DependencyBundler_Filter.isNecessary — exclusion reasons", () => {
  let base = (~excludeScopes=[], ~excludeModules=[], ~includeModules=[], ~includeScopes=[], n) =>
    F.isNecessary(~excludeScopes, ~excludeModules, ~includeModules, ~includeScopes, n)

  testSync("a dev dependency is unnecessary (Dev)", () =>
    expect(base(node(~name="jest", ~dev=true)))->toEqual(Some(F.Dev))
  )
  testSync("an optional dependency is unnecessary (Optional)", () =>
    expect(base(node(~name="fsevents", ~optional=true)))->toEqual(Some(F.Optional))
  )
  testSync("a devOptional dependency is unnecessary (DevOptional)", () =>
    expect(base(node(~name="x", ~devOptional=true)))->toEqual(Some(F.DevOptional))
  )
  testSync("a peer dependency is unnecessary (Peer)", () =>
    expect(base(node(~name="react", ~peer=true)))->toEqual(Some(F.Peer))
  )
  testSync("a node under an excluded scope is unnecessary (ScopeExcluded)", () =>
    expect(base(~excludeScopes=["types"], node(~name="@types/node")))->toEqual(Some(F.ScopeExcluded))
  )
  testSync("an explicitly excluded module is unnecessary (ModuleExcluded)", () =>
    expect(base(~excludeModules=["aws-sdk"], node(~name="aws-sdk")))->toEqual(Some(F.ModuleExcluded))
  )
  testSync("includeModules overrides every exclusion — even a dev dep is kept", () =>
    expect(base(~includeModules=["jest"], node(~name="jest", ~dev=true)))->toEqual(None)
  )
  testSync("includeScopes keeps a whole scope — even a peer dep is kept", () =>
    expect(
      base(~includeScopes=["smithy"], node(~name="@smithy/middleware-endpoint", ~peer=true)),
    )->toEqual(None)
  )
  testSync("includeScopes keeps a scope even when that scope is also excluded", () =>
    // Force-keep wins over scope exclusion — the @smithy regression: its only
    // dependents are the excluded @aws-sdk clients, yet it must stay in the layer.
    expect(
      base(
        ~excludeScopes=["smithy"],
        ~includeScopes=["smithy"],
        node(~name="@smithy/middleware-endpoint"),
      ),
    )->toEqual(None)
  )
})

describe("DependencyBundler_Filter.predIsNecessary", () => {
  testSync("false for an excluded (dev) node", () =>
    expect(
      F.predIsNecessary(~excludeScopes=[], ~excludeModules=[], node(~name="jest", ~dev=true)),
    )->toEqual(false)
  )
  testSync("true for an included node", () =>
    expect(
      F.predIsNecessary(
        ~excludeScopes=[],
        ~excludeModules=[],
        ~includeModules=["jest"],
        node(~name="jest", ~dev=true),
      ),
    )->toEqual(true)
  )
})
