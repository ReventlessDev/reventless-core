// Run by JestTest.mjs: `Only.test` must leave its neighbour skipped.
open Jest
open Expect

Only.test("Only.test passes", () => expect(true)->toBe(true))
test("a test beside Only.test is skipped", () => fail("ran beside Only.test"))
