// Untyped JS primitives for Util_LogGroup_Adopting.
//
// The AWS SDK is imported dynamically there (a Pulumi dynamic provider
// serialises its whole captured closure into stack state, and a statically
// captured SDK does not survive that), so its command classes arrive as plain
// values on a module namespace and cannot be reached through `@new external`.
// These three helpers are the only untyped reflection that needs, kept out of
// the ReScript source.

/** `new Ctor(input)` — the SDK exports plain classes. */
export const newCommand = (Ctor, input) => new Ctor(input)

/** `new Ctor()` — the client constructor takes no required argument. */
export const newClient = Ctor => new Ctor()

/** Rethrows a JavaScript error as-is, bypassing the ReScript exception wrapper,
    so Pulumi prints AWS's own message rather than "error: undefined". */
export const rethrow = e => {
  throw e
}
