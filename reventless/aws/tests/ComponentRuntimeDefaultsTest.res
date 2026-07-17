open JestGlobals

// The per-kind EP/task pod floor is now supplied by each platform's `Defaults`
// module (RuntimeDefaults.T) and fed into RuntimeHints.resolveMemory/resolveTimeout
// by the core builders, replacing core's old hardcoded literals. These guard that
// the AWS binding stays behavior-preserving: EP pods still floor at 1024 MiB / 30 s
// and task pods at 4096 MiB / 600 s. A plugin.json `runtime` override still raises
// memory (Math.Int.max) and replaces timeout on top of these — see RuntimeHintsTest.

describe("AWS extension-point runtime defaults", () => {
  testSync("memory floor is 1024 MiB", () => {
    expect(ExtensionPoint_Builder.Defaults.memorySize)->toBe(1024)
  })
  testSync("timeout floor is 30 s", () => {
    expect(ExtensionPoint_Builder.Defaults.timeout)->toBe(30)
  })
})

describe("AWS task runtime defaults", () => {
  testSync("memory floor is 4096 MiB", () => {
    expect(Task_Builder_PerBucket.Defaults.memorySize)->toBe(4096)
  })
  testSync("timeout floor is 600 s", () => {
    expect(Task_Builder_PerBucket.Defaults.timeout)->toBe(600)
  })
})
