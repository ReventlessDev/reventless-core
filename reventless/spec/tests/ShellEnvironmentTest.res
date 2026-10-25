open JestGlobals

// What the shell is told about its environment. The case that matters most is
// production: it is the one the shell draws no badge for.

let provenance = (~environment=?, ~purpose=?) => {
  DeploymentProvenance.commit: ?None,
  dirty: false,
  ?environment,
  ?purpose,
}

let resolve = (provenance, ~stack) =>
  ShellEnvironment.resolve(~provenance, ~stack, ~prodStacks=["prod", "main"])

describe("ShellEnvironment.resolve", () => {
  testSync("a declared environment wins over the stack", () =>
    expect(resolve(provenance(~environment="test", ~purpose="test"), ~stack="test-eu"))->toEqual({
      ShellEnvironment.name: "test",
      purpose: "test",
    })
  )

  testSync("an undeclared production stack is production", () =>
    expect(resolve(provenance(), ~stack="prod"))->toEqual({
      ShellEnvironment.name: "prod",
      purpose: "production",
    })
  )

  testSync("any other undeclared stack has no known purpose", () =>
    expect(resolve(provenance(), ~stack="alpha"))->toEqual({
      ShellEnvironment.name: "alpha",
    })
  )

  testSync("a team's own purpose is passed through unchanged", () =>
    expect(
      resolve(provenance(~environment="eu", ~purpose="staging"), ~stack="prod").purpose,
    )->toEqual(Some("staging"))
  )
})

describe("ShellEnvironment.configFields", () => {
  testSync("both keys when the purpose is known", () =>
    expect(ShellEnvironment.local->ShellEnvironment.configFields)->toEqual([
      ("environment", JSON.Encode.string("local")),
      ("environmentPurpose", JSON.Encode.string("local")),
    ])
  )

  testSync("no purpose key when it is not", () =>
    expect({ShellEnvironment.name: "alpha"}->ShellEnvironment.configFields)->toEqual([
      ("environment", JSON.Encode.string("alpha")),
    ])
  )
})
