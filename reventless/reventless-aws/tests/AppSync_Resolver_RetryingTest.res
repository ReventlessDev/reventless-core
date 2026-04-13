open TestHelpers

// Helper: build a plain JS object shaped like a JS Error / SDK exception.
// Obj.magic casts the ReScript record (which compiles to a plain JS object)
// to JsExn.t so we can call isFieldNotFoundError without a real throw/catch.
type testError = {name: string, message: string}

let mkErr = (~name, ~message): JsExn.t =>
  Obj.magic(({name, message}: testError))

describe("AppSync_Resolver_Retrying.isFieldNotFoundError", () => {
  describe("returns true", () => {
    test("NotFoundException with 'No field named' message", () => {
      let err = mkErr(
        ~name="NotFoundException",
        ~message="No field named createFoo found on type Mutation",
      )
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(err))->toBe(true)
    })

    test("NotFoundException with 'No field named' on Query type", () => {
      let err = mkErr(
        ~name="NotFoundException",
        ~message="No field named bar found on type Query",
      )
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(err))->toBe(true)
    })
  })

  describe("returns false", () => {
    test("NotFoundException with 'No resolver found' (delete-path — must not retry)", () => {
      let err = mkErr(
        ~name="NotFoundException",
        ~message="No resolver found for type Query field foo",
      )
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(err))->toBe(false)
    })

    test("ThrottlingException", () => {
      let err = mkErr(~name="ThrottlingException", ~message="Rate exceeded")
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(err))->toBe(false)
    })

    test("NotFoundException with unrelated message", () => {
      let err = mkErr(~name="NotFoundException", ~message="API not found")
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(err))->toBe(false)
    })

    test("non-exception value (integer)", () => {
      let notErr: JsExn.t = Obj.magic(42)
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(notErr))->toBe(false)
    })

    test("non-exception value (plain object without name)", () => {
      let notErr: JsExn.t = Obj.magic({"message": "something went wrong"})
      expect(AppSync_Resolver_Retrying.isFieldNotFoundError(notErr))->toBe(false)
    })
  })
})
