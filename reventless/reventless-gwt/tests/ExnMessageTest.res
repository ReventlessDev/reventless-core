// Pins `ExnMessage.extract` across the value shapes it inspects: ReScript
// exceptions (matched or reflected via `RE_EXN_ID`/`_1`), thrown JS `Error`s,
// bare thrown strings, and non-message values. The reflective cases are the
// reason the extractor exists, so they are asserted explicitly.

open JestGlobals

exception Boom(string)
exception NoPayload

// Fixtures the type system can't produce as a well-typed `exn`.
let jsError: exn = %raw(`new Error("kaboom")`)
let rawString: exn = %raw(`"just a string"`)
let nullish: exn = %raw(`null`)
let bareObject: exn = %raw(`({ some: "thing" })`)

describe("ExnMessage.extract", () => {
  testSync("Failure carries its message (the failwith path)", () =>
    expect(ExnMessage.extract(Failure("not implemented: X")))->toEqual("not implemented: X")
  )
  testSync("empty Failure falls back to the constructor tag", () =>
    expect(ExnMessage.extract(Failure("")))->toEqual("Failure")
  )
  testSync("a custom exception with a string payload yields the payload", () =>
    expect(ExnMessage.extract(Boom("custom boom")))->toEqual("custom boom")
  )
  testSync("a payload-less custom exception yields its constructor tag", () =>
    expect(ExnMessage.extract(NoPayload))->toEqual("NoPayload")
  )
  testSync("a thrown JS Error yields its .message", () =>
    expect(ExnMessage.extract(jsError))->toEqual("kaboom")
  )
  testSync("a bare thrown string is returned as-is", () =>
    expect(ExnMessage.extract(rawString))->toEqual("just a string")
  )
  testSync("a value with no message/RE_EXN_ID falls back", () =>
    expect(ExnMessage.extract(bareObject))->toEqual("unknown error")
  )
  testSync("null-ish falls back", () =>
    expect(ExnMessage.extract(nullish))->toEqual("unknown error")
  )
})
