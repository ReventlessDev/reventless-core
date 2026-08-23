// Throws the shape an AWS SDK v3 client actually throws, so a test catches it
// through the same path the real code does.
//
// It has to *throw* rather than return: ReScript's `exn` for a JS error is the
// wrapper its own catch builds, not the bare `Error` object. A fixture that
// returned one would be a different value than any real call produces, and a test
// built on it would prove nothing about the code that catches them.
//
// Here rather than in a `%raw` inside the test, per the repo convention that
// untyped reflection lives in a companion `.mjs` bound through `@module`.

export const throwAwsError = (name, message) => {
  const error = new Error(message)
  error.name = name
  throw error
}
