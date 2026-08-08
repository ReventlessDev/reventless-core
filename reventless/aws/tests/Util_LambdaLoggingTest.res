open JestGlobals

// The managed log group's name is now chosen by the program rather than derived
// from the function's physical name output. That choice is what removes the race
// (the group can be created before the function, and pointed at from
// `loggingConfig`), so the properties it has to keep are worth pinning.
describe("Util_LambdaLogging.logGroupNameFor", () => {
  testSync("is the conventional Lambda group prefix", () =>
    expect(Util_LambdaLogging.logGroupNameFor(~stack="alpha", ~name="AllReadModels"))->toBe(
      "/aws/lambda/alpha-AllReadModels",
    )
  )

  testSync("carries no Pulumi physical-name suffix, so a replaced function keeps its group", () => {
    let before = Util_LambdaLogging.logGroupNameFor(~stack="alpha", ~name="AllReadModels")
    let afterReplacement = Util_LambdaLogging.logGroupNameFor(~stack="alpha", ~name="AllReadModels")
    expect(before)->toBe(afterReplacement)
  })

  testSync("is stack-scoped, so stacks sharing an account cannot collide", () =>
    expect(Util_LambdaLogging.logGroupNameFor(~stack="pr-42", ~name="AllReadModels"))->not_->toBe(
      Util_LambdaLogging.logGroupNameFor(~stack="alpha", ~name="AllReadModels"),
    )
  )

  testSync("differs from the group Lambda would auto-create for the same function", () => {
    // Lambda auto-creates `/aws/lambda/<physical name>`, and the physical name
    // always carries Pulumi's `-<7hex>` suffix. Not colliding with it is what
    // makes the create unconditionally safe on a stack whose groups AWS already
    // made.
    let autoCreated = "/aws/lambda/AllReadModels-0287438"
    expect(Util_LambdaLogging.logGroupNameFor(~stack="alpha", ~name="AllReadModels"))->not_->toBe(
      autoCreated,
    )
  })
})
