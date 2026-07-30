// Pins `PlatformManifests.resolve` — which capability manifests a
// deploy-manifest entry contributes, and the evidence separating "not a plugin"
// from "a plugin that has not been built".
//
// That separation is the whole risk of the non-plugin arm: falling through on a
// genuinely missing manifest would drop the plugin's stores from the platform's
// capability list and deprovision them. So each arm is pinned both ways — what
// it resolves, and what it refuses to resolve.
//
// The arms are exercised against an in-memory file system rather than a fixture
// tree: node_modules layouts (local, hoisted, scoped) are the point of the
// dependency arm, and spelling them as data keeps them readable and the suite
// free of disk state.

open JestGlobals
// For the result constructors — `resolve` stays qualified at every call site.
open PlatformManifests

let fakeFs =(files: array<(string, string)>): PlatformManifests.fileSystem => {
  let byPath = Dict.fromArray(files)
  {
    exists: path => byPath->Dict.get(path)->Option.isSome,
    readJson: path =>
      byPath
      ->Dict.get(path)
      ->Option.flatMap(source =>
        try Some(source->JSON.parseOrThrow) catch {
        | _ => None
        }
      ),
  }
}

let emptyManifest = `{"capabilities": []}`
let compositionPackageJson = `{"name": "@acme/catalog", "scripts": {"postbuild": "emit-capabilities src/"}}`

describe("PlatformManifests.resolve", () => {
  describe("arm 1 — the entry is itself a composition package", () =>
    testSync("its own src/capabilities.json is the manifest", () => {
      let fs = fakeFs([("/repo/catalog/src/capabilities.json", emptyManifest)])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/catalog"))->toEqual(
        Manifests([{path: "/repo/catalog/src/capabilities.json", via: Composition}]),
      )
    })
  )

  describe("arm 2 — an -aws root generated from a composition src/ in the same repo", () => {
    let generatedRoot = `{"scripts": {"generate": "generate-plugin --aws CatalogPlugin ../catalog/src/"}}`

    testSync("the `generate` script leads to the composition's manifest", () => {
      let fs = fakeFs([
        ("/repo/catalog-aws/package.json", generatedRoot),
        ("/repo/catalog/src/capabilities.json", emptyManifest),
      ])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/catalog-aws"))->toEqual(
        Manifests([
          {path: "/repo/catalog/src/capabilities.json", via: Generated("../catalog/src/")},
        ]),
      )
    })

    // The pre-existing hard failure, unchanged: the script says this is a
    // plugin, so an absent manifest means unbuilt, never "not a plugin".
    testSync("an unbuilt composition is Unbuilt, not NotAPlugin", () =>
      switch PlatformManifests.resolve(
        ~fs=fakeFs([("/repo/catalog-aws/package.json", generatedRoot)]),
        ~pluginDir="/repo/catalog-aws",
      ) {
      | Unbuilt({evidence, expected}) => {
          expect(evidence->String.includes("../catalog/src/"))->toBe(true)
          expect(expected)->toBe("/repo/catalog/src/capabilities.json")
        }
      | _ => expect("Unbuilt")->toBe("something else")
      }
    )
  })

  describe("arm 3 — an -aws root that installs a published composition package", () => {
    let installingRoot = `{"dependencies": {"@acme/catalog": "^1.0.0", "@reventlessdev/reventless-aws": "^3.0.0"}}`
    let frameworkPackageJson = `{"name": "@reventlessdev/reventless-aws", "scripts": {"build": "rescript build"}}`

    // The shape the framework recommends, which arms 1 and 2 both miss: nothing
    // is generated on the root and the manifest ships inside the dependency.
    testSync("the dependency's manifest resolves, naming the package", () => {
      let fs = fakeFs([
        ("/repo/catalog-aws/package.json", installingRoot),
        ("/repo/catalog-aws/node_modules/@acme/catalog/package.json", compositionPackageJson),
        ("/repo/catalog-aws/node_modules/@acme/catalog/src/capabilities.json", emptyManifest),
        (
          "/repo/catalog-aws/node_modules/@reventlessdev/reventless-aws/package.json",
          frameworkPackageJson,
        ),
      ])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/catalog-aws"))->toEqual(
        Manifests([
          {
            path: "/repo/catalog-aws/node_modules/@acme/catalog/src/capabilities.json",
            via: Dependency("@acme/catalog"),
          },
        ]),
      )
    })

    testSync("a hoisted dependency is found by walking up to the parent node_modules", () => {
      let fs = fakeFs([
        ("/repo/deploy/catalog-aws/package.json", installingRoot),
        ("/repo/node_modules/@acme/catalog/package.json", compositionPackageJson),
        ("/repo/node_modules/@acme/catalog/src/capabilities.json", emptyManifest),
      ])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/deploy/catalog-aws"))->toEqual(
        Manifests([
          {
            path: "/repo/node_modules/@acme/catalog/src/capabilities.json",
            via: Dependency("@acme/catalog"),
          },
        ]),
      )
    })

    // A root deploying two plugins legitimately requires both, so the arm
    // unions rather than choosing.
    testSync("two plugin dependencies both contribute", () => {
      let fs = fakeFs([
        (
          "/repo/root/package.json",
          `{"dependencies": {"@acme/catalog": "^1", "@acme/ordering": "^1"}}`,
        ),
        ("/repo/root/node_modules/@acme/catalog/package.json", compositionPackageJson),
        ("/repo/root/node_modules/@acme/catalog/src/capabilities.json", emptyManifest),
        ("/repo/root/node_modules/@acme/ordering/package.json", compositionPackageJson),
        ("/repo/root/node_modules/@acme/ordering/src/capabilities.json", emptyManifest),
      ])
      switch PlatformManifests.resolve(~fs, ~pluginDir="/repo/root") {
      | Manifests(manifests) =>
        expect(manifests->Array.map(m => PlatformManifests.describeVia(m.via)))->toEqual([
          "dependency @acme/catalog",
          "dependency @acme/ordering",
        ])
      | _ => expect("Manifests")->toBe("something else")
      }
    })

    // The risk the non-plugin arm carries, pinned: an installed plugin package
    // that has not been built must fail, not contribute nothing.
    testSync("an installed but unbuilt plugin dependency is Unbuilt", () =>
      switch PlatformManifests.resolve(
        ~fs=fakeFs([
          ("/repo/catalog-aws/package.json", installingRoot),
          ("/repo/catalog-aws/node_modules/@acme/catalog/package.json", compositionPackageJson),
        ]),
        ~pluginDir="/repo/catalog-aws",
      ) {
      | Unbuilt({evidence}) => expect(evidence->String.includes("@acme/catalog"))->toBe(true)
      | _ => expect("Unbuilt")->toBe("something else")
      }
    )

    // One built plugin does not excuse the other: the platform needs both.
    testSync("an unbuilt plugin dependency fails even when a sibling resolved", () =>
      switch PlatformManifests.resolve(
        ~fs=fakeFs([
          (
            "/repo/root/package.json",
            `{"dependencies": {"@acme/catalog": "^1", "@acme/ordering": "^1"}}`,
          ),
          ("/repo/root/node_modules/@acme/catalog/package.json", compositionPackageJson),
          ("/repo/root/node_modules/@acme/catalog/src/capabilities.json", emptyManifest),
          ("/repo/root/node_modules/@acme/ordering/package.json", compositionPackageJson),
        ]),
        ~pluginDir="/repo/root",
      ) {
      | Unbuilt({evidence}) => expect(evidence->String.includes("@acme/ordering"))->toBe(true)
      | _ => expect("Unbuilt")->toBe("something else")
      }
    )
  })

  describe("arm 4 — the entry is not a plugin", () => {
    // An SdkService stack: real deployable, real dependencies, no composition
    // anywhere in its package graph. Nothing to contribute is the right answer.
    testSync("a stack depending on no plugin package contributes nothing", () => {
      let fs = fakeFs([
        ("/repo/sdk-service/package.json", `{"dependencies": {"@reventlessdev/reventless-aws": "^3"}}`),
        (
          "/repo/sdk-service/node_modules/@reventlessdev/reventless-aws/package.json",
          `{"scripts": {"build": "rescript build"}}`,
        ),
      ])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/sdk-service"))->toEqual(NotAPlugin)
    })

    testSync("a stack with no package.json at all contributes nothing", () =>
      expect(PlatformManifests.resolve(~fs=fakeFs([]), ~pluginDir="/repo/spa"))->toEqual(NotAPlugin)
    )

    // `reventless-local` exposes emit-capabilities under `bin`, not `scripts` —
    // it provides the bin rather than running it, so depending on it is not
    // evidence of a plugin.
    testSync("a dependency that only provides the emit-capabilities bin is not a plugin", () => {
      let fs = fakeFs([
        ("/repo/tool/package.json", `{"dependencies": {"@reventlessdev/reventless-local": "^3"}}`),
        (
          "/repo/tool/node_modules/@reventlessdev/reventless-local/package.json",
          `{"bin": {"emit-capabilities": "./emit-capabilities.mjs"}, "scripts": {"build": "rescript build"}}`,
        ),
      ])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/tool"))->toEqual(NotAPlugin)
    })
  })

  describe("resolution order", () =>
    // Arm 1 is checked before the package.json is read at all, so a composition
    // package that also happens to carry a `generate` script cannot resolve to
    // the wrong file.
    testSync("its own src/ wins over a `generate` script pointing elsewhere", () => {
      let fs = fakeFs([
        ("/repo/catalog/src/capabilities.json", emptyManifest),
        (
          "/repo/catalog/package.json",
          `{"scripts": {"generate": "generate-plugin --aws CatalogPlugin ../other/src/"}}`,
        ),
        ("/repo/other/src/capabilities.json", emptyManifest),
      ])
      expect(PlatformManifests.resolve(~fs, ~pluginDir="/repo/catalog"))->toEqual(
        Manifests([{path: "/repo/catalog/src/capabilities.json", via: Composition}]),
      )
    })
  )
})
