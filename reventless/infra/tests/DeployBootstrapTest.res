open JestGlobals

module DB = DeployBootstrap

describe("DeployBootstrap", () => {
  // The seam holds module-level state, so each case resets first for isolation.
  describe("run with no registrations", () => {
    testSync("is a no-op that does not throw", () => {
      DB.reset()
      DB.run(PreDeploy)
      DB.run(PostDeploy)
      expect(true)->toBe(true)
    })
  })

  describe("registration order within a phase", () => {
    testSync("runs contributions in the order they were registered", () => {
      DB.reset()
      let calls = []
      DB.register(() => calls->Array.push("a"))
      DB.register(() => calls->Array.push("b"))
      DB.register(() => calls->Array.push("c"))
      DB.run(PreDeploy)
      expect(calls)->toEqual(["a", "b", "c"])
    })
  })

  describe("phase isolation", () => {
    testSync("run(PreDeploy) fires only PreDeploy contributions", () => {
      DB.reset()
      let calls = []
      DB.register(~phase=PreDeploy, () => calls->Array.push("pre"))
      DB.register(~phase=PostDeploy, () => calls->Array.push("post"))
      DB.run(PreDeploy)
      expect(calls)->toEqual(["pre"])
      DB.run(PostDeploy)
      expect(calls)->toEqual(["pre", "post"])
    })

    testSync("defaults to PreDeploy when no phase is given", () => {
      DB.reset()
      let calls = []
      DB.register(() => calls->Array.push("default"))
      DB.run(PostDeploy)
      expect(calls)->toEqual([])
      DB.run(PreDeploy)
      expect(calls)->toEqual(["default"])
    })
  })

  describe("idempotent run per phase", () => {
    testSync("running an already-run phase does nothing", () => {
      DB.reset()
      let count = ref(0)
      DB.register(() => count := count.contents + 1)
      DB.run(PreDeploy)
      DB.run(PreDeploy)
      DB.run(PreDeploy)
      expect(count.contents)->toBe(1)
    })

    testSync("a contribution registered after run does not fire", () => {
      DB.reset()
      let calls = []
      DB.register(() => calls->Array.push("before"))
      DB.run(PreDeploy)
      DB.register(() => calls->Array.push("after"))
      DB.run(PreDeploy)
      expect(calls)->toEqual(["before"])
    })
  })
})
