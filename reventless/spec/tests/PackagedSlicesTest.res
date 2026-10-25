// A plugin lists slices an installed package provides, in plugin.json's
// `slicesFrom`, and composes them as its own: aliased under their bare names,
// read from the package for everything the generator reads off source, and
// given the chapter the package files them under.

open JestGlobals

let scratch = () => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "packaged-slices-"]))

let write = (root, rel, text) => {
  let path = NodePath.join([root, rel])
  NodeFs.mkdirSync(NodePath.dirname(path), {recursive: true})
  NodeFs.writeFileSync(path, text)
}

let package = "@example/registration-slices"
let packageDir = "node_modules/@example/registration-slices"

/** A plugin with one slice of its own and, unless told otherwise, a package of
    three: a policy whose decision is applied to the app's declaration, a door
    marked as admission's start, and an identity. */
let fixture = (~pluginJson, ~packageFiles=?, ~namespace=Some("RegistrationSlices"), ()) => {
  let root = scratch()
  write(root, "package.json", `{"name": "@example/shop-registration"}`)
  write(root, "src/plugin.json", pluginJson)
  write(root, "src/Admission.res", `let table = []`)
  write(root, "src/Account/StateChange/Accounts.res", `@@reventless.spec`)
  write(root, "src/Account/StateChange/Accounts_Decision.res", `@@reventless.decision`)
  write(root, `${packageDir}/package.json`, `{"name": "${package}"}`)
  write(
    root,
    `${packageDir}/rescript.json`,
    switch namespace {
    | Some(n) => `{"name": "${package}", "namespace": "${n}"}`
    | None => `{"name": "${package}"}`
    },
  )
  let files = packageFiles->Option.getOr([
    ("Registration/StateChange/Policy.res", `@@reventless.spec`),
    (
      "Registration/StateChange/Policy_Decision.res",
      "@@reventless.decision\n\nmodule Make = (App: Reventless.Admission.Declaration) => {\n}",
    ),
    (
      "Registration/InboundTranslation/SignUp.res",
      "@@reventless.spec\nlet targetName = \"Policy\"\nlet admissionDoor = Reventless.Admission.Start",
    ),
    ("Registration/InboundTranslation/SignUp_Translation.res", `@@reventless.translation`),
    (
      "Registration/ContactAddressId.res",
      `include Reventless.Id.Make({let key = "contactAddress"})`,
    ),
    // A test beside the source is no component, in a package as in a plugin.
    ("Registration/StateChange/PolicyTest.res", `let x = 1`),
  ])
  files->Array.forEach(((rel, text)) => write(root, `${packageDir}/src/${rel}`, text))
  root
}

let generate = root =>
  PluginGenerator.render(
    ~srcDir=NodePath.join([root, "src"]),
    ~variant=Config.Composition,
  )->Pair.second

let refusal = root =>
  switch generate(root) {
  | _ => None
  | exception JsExn(e) => e->JsExn.message
  }

let listing = `{"name": "Registration", "slicesFrom": [{"package": "${package}", "with": "Admission"}]}`

describe("a plugin composing slices from a package", () => {
  let root = fixture(~pluginJson=listing, ())
  let source = generate(root)
  NodeFs.rmSync(root, {recursive: true, force: true})
  let has = needle => source->String.includes(needle)

  testSync("each module is aliased from the package's namespace under its bare name", () => {
    expect(has("module Policy = RegistrationSlices.Policy\n"))->toBe(true)
    expect(has("module SignUp = RegistrationSlices.SignUp\n"))->toBe(true)
    expect(has("module SignUp_Translation = RegistrationSlices.SignUp_Translation\n"))->toBe(true)
  })

  testSync("a body written as a functor is applied to the module `with` names", () =>
    expect(
      has("module Policy_Decision = RegistrationSlices.Policy_Decision.Make(Admission)"),
    )->toBe(true)
  )

  testSync("the aliases precede everything that names them", () =>
    expect(
      source->String.indexOf("module Policy =") < source->String.indexOf("dcbSliceSchemas"),
    )->toBe(true)
  )

  testSync("its slices are composed beside the plugin's own", () => {
    expect(
      has("module PolicySlice = Platform.StateChangeSlice.Make(Policy, Policy_Decision)"),
    )->toBe(true)
    expect(
      has("module AccountsSlice = Platform.StateChangeSlice.Make(Accounts, Accounts_Decision)"),
    )->toBe(true)
    expect(
      has("module SignUpSlice = Platform.InboundTranslationSlice.Make(SignUp, SignUp_Translation)"),
    )->toBe(true)
  })

  testSync("a packaged slice takes the chapter the package files it under", () =>
    expect(has(`("Policy", "Registration")`) && has(`("Accounts", "Account")`))->toBe(true)
  )

  testSync("what the generator reads off source is read from the package", () => {
    expect(has("(SignUp.name, SignUp.admissionDoor)"))->toBe(true)
    expect(has("~identities=[ContactAddressId.key]"))->toBe(true)
    expect(has("module ContactAddressId = RegistrationSlices.ContactAddressId"))->toBe(true)
  })

  testSync("a test file in the package is not a component", () =>
    expect(has("PolicyTest"))->toBe(false)
  )
})

describe("a plugin listing no package", () => {
  let root = fixture(~pluginJson=`{"name": "Registration"}`, ())
  let source = generate(root)
  NodeFs.rmSync(root, {recursive: true, force: true})

  testSync("has no aliases and none of the package's slices", () => {
    expect(source->String.includes("// Slices from"))->toBe(false)
    expect(source->String.includes("Policy"))->toBe(false)
  })
})

describe("a listing that cannot be honored is refused", () => {
  let refused = (~pluginJson=listing, ~packageFiles=?, ~namespace=?, ~mentions) => {
    let root = fixture(~pluginJson, ~packageFiles?, ~namespace?, ())
    let why = refusal(root)
    NodeFs.rmSync(root, {recursive: true, force: true})
    expect(why->Option.map(m => mentions->Array.every(s => m->String.includes(s))))->toEqual(
      Some(true),
    )
  }

  testSync("a package that is not installed", () =>
    refused(
      ~pluginJson=`{"slicesFrom": [{"package": "@example/absent"}]}`,
      ~mentions=["@example/absent", "not installed"],
    )
  )

  testSync("a package that names no namespace", () =>
    refused(~namespace=None, ~mentions=[package, "namespace"])
  )

  testSync("a package providing something other than a slice", () =>
    refused(
      ~packageFiles=[("Registration/Aggregate/Account.res", `@@reventless.spec`)],
      ~mentions=["Registration/Aggregate/Account.res", "not a slice"],
    )
  )

  testSync("a package providing nothing", () =>
    refused(~packageFiles=[], ~mentions=[package, "provides none"])
  )

  testSync("a functor body with no module to apply it to", () =>
    refused(
      ~pluginJson=`{"slicesFrom": [{"package": "${package}"}]}`,
      ~mentions=["Policy_Decision.res", `"with"`],
    )
  )

  testSync("an entry naming no package", () =>
    refused(~pluginJson=`{"slicesFrom": [{"with": "Admission"}]}`, ~mentions=["names a package"])
  )

  testSync("a stem the plugin and the package both use", () =>
    refused(
      ~packageFiles=[
        ("Registration/StateChange/Accounts.res", `@@reventless.spec`),
        ("Registration/StateChange/Accounts_Decision.res", `@@reventless.decision`),
      ],
      ~mentions=["Accounts", "multiple files"],
    )
  )
})
