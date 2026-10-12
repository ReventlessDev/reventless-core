// Run by JestTest.mjs in a child Jest, never by the repo's own run: some of
// these tests exist to fail. Each test's name states the outcome expected.
open Jest
open Expect

let sleep = ms =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), ms)
  })

describe("matchers", () => {
  test("toBe passes", () => expect(1)->toBe(1))
  test("not_ toBe passes", () => expect(1)->not_->toBe(2))
  test("toEqual passes", () => expect([1, 2])->toEqual([1, 2]))
  test("toBeCloseTo passes", () => expect(0.1 +. 0.2)->toBeCloseTo(0.3))
  test("toBeSoCloseTo passes", () => expect(3.14159)->toBeSoCloseTo(3.14, ~digits=2))
  test("toBeGreaterThan passes", () => expect(2)->toBeGreaterThan(1))
  test("toBeLessThanOrEqual passes", () => expect(1)->toBeLessThanOrEqual(1))
  test("toBeSupersetOf passes", () => expect([1, 2, 3])->toBeSupersetOf([3, 1]))
  test("toContain passes", () => expect(["a", "b"])->toContain("b"))
  test("toContainEqual passes", () => expect([[1], [2]])->toContainEqual([2]))
  test("toContainString passes", () => expect("haystack")->toContainString("st"))
  test("toHaveLength passes", () => expect([1, 2, 3])->toHaveLength(3))
  test("toMatch passes", () => expect("abc")->toMatch("^a.c$"))
  test("toMatchRe passes", () => expect("ABC")->toMatchRe(/abc/i))
  test("toThrow passes", () => expect(() => JsError.throwWithMessage("boom"))->toThrow)
  test("expectFn toThrow passes", () => expectFn(JsError.throwWithMessage, "boom")->toThrow)
  test("Operators pass", () => {
    open! Operators
    let _ = expect(1) == 1
    expect([1]) != [2]
  })
  test("pass passes", () => pass)
})

describe("runners", () => {
  let settled = ref(false)
  testPromise("testPromise passes", async () => {
    await sleep(10)
    settled := true
    expect(1)->toBe(1)
  })
  test("the next test starts after testPromise settles passes", () =>
    expect(settled.contents)->toBe(true)
  )
  testAsync("testAsync passes", finish => {
    let _ = setTimeout(() => finish(expect(1)->toBe(1)), 10)
  })
  testAll("testAll passes", list{1, 2}, n => expect(n > 0)->toBe(true))
  testAllPromise("testAllPromise passes", list{"a"}, async s => {
    await sleep(1)
    expect(s)->toBe("a")
  })
})

describe("hooks", () => {
  let log = []
  beforeAllPromise(async () => log->Array.push("beforeAll"))
  beforeEachAsync(finish => {
    log->Array.push("beforeEach")
    finish()
  })
  afterEachPromise(async () => log->Array.push("afterEach"))
  test("first test sees beforeAll and beforeEach passes", () =>
    expect(log)->toEqual(["beforeAll", "beforeEach"])
  )
  test("second test sees afterEach passes", () =>
    expect(log)->toEqual(["beforeAll", "beforeEach", "afterEach", "beforeEach"])
  )
})

describe("timers", () => {
  test("advanceTimersByTime passes", () => {
    Jest.useFakeTimers()
    let fired = ref(false)
    let _ = setTimeout(() => fired := true, 1000)
    Jest.advanceTimersByTime(1000)
    Jest.useRealTimers()
    expect(fired.contents)->toBe(true)
  })
  test("setSystemTime passes", () => {
    Jest.useFakeTimers()
    Jest.setSystemTime(#date(Date.fromTime(86400000.0)))
    let now = Date.now()
    Jest.useRealTimers()
    expect(now)->toBe(86400000.0)
  })
})

describe("checked now", () => {
  test("a failing assertion in the middle fails", () => {
    let _ = expect(1)->toBe(2)
    expect(1)->toBe(1)
  })
  testPromise("a testPromise failing after a delay fails", async () => {
    await sleep(20)
    expect("late")->toBe("on time")
  })
  testAsync("a testAsync that never calls done times out", ~timeout=200, _finish => ())
  test("fail fails", () => fail("failed on purpose"))
  Skip.test("Skip.test is skipped", () => fail("a skipped test ran"))
  Todo.test("Todo.test is a todo")
})
