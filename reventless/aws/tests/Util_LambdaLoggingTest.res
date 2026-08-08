open JestGlobals

// The managed log group's name is now chosen by the program rather than derived
// from the function's physical name output. That choice is what removes the race
// (the group can be created before the function, and pointed at from
// `loggingConfig`), so the properties it has to keep are worth pinning.
describe("Util_LambdaLogging.logGroupNameFor", () => {
  let nameFor = (~project="online-shop-catalog-aws", ~stack="alpha", ~name) =>
    Util_LambdaLogging.logGroupNameFor(~project, ~stack, ~name)

  testSync("is the conventional Lambda group prefix", () =>
    expect(nameFor(~name="AllReadModels"))->toBe(
      "/aws/lambda/online-shop-catalog-aws-alpha-AllReadModels",
    )
  )

  testSync("carries no Pulumi physical-name suffix, so a replaced function keeps its group", () => {
    let before = nameFor(~name="AllReadModels")
    let afterReplacement = nameFor(~name="AllReadModels")
    expect(before)->toBe(afterReplacement)
  })

  testSync("is stack-scoped, so environments of one project cannot collide", () =>
    expect(nameFor(~stack="pr-42", ~name="AllReadModels"))->not_->toBe(
      nameFor(~stack="alpha", ~name="AllReadModels"),
    )
  )

  // The regression this scoping exists for. Every plugin of one platform is its
  // own Pulumi PROJECT deployed under the SAME stack name, and components are
  // named by role rather than by owner — so several projects each host an
  // `AllStateViewSlices`. Scoping on the stack alone gave them one name, and
  // every deploy after the first failed with ResourceAlreadyExistsException.
  testSync("is project-scoped, so one platform's plugins cannot collide", () =>
    expect(nameFor(~project="online-shop-catalog-aws", ~name="AllStateViewSlices"))
    ->not_
    ->toBe(nameFor(~project="online-shop-ordering-aws", ~name="AllStateViewSlices"))
  )

  testSync("differs from the group Lambda would auto-create for the same function", () => {
    // Lambda auto-creates `/aws/lambda/<physical name>`, and the physical name
    // always carries Pulumi's `-<7hex>` suffix. Not colliding with it is what
    // makes the create unconditionally safe on a stack whose groups AWS already
    // made.
    let autoCreated = "/aws/lambda/AllReadModels-0287438"
    expect(nameFor(~name="AllReadModels"))->not_->toBe(autoCreated)
  })
})
