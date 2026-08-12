// A failure the caller is allowed to read.
//
// graphql-yoga's `maskedErrors` replaces any thrown value that is not a
// `GraphQLError` with "Unexpected error / INTERNAL_SERVER_ERROR". That is the
// right default — an internal failure's message is not the caller's business —
// but it also hides the failures that describe the caller's own request, which
// are the ones they can do something about. Constructing the error through this
// module is how a resolver says "this one is theirs to read".
//
// Mirrors what AppSync surfaces in production, where a resolver's thrown message
// is returned as the field error.

@new @module("graphql")
external make: (string, {"extensions": {"code": string}}) => exn = "GraphQLError"

/** A request the server understood and refused — bad input, in GraphQL's own
    `BAD_USER_INPUT` sense. */
let badUserInput = (message: string): exn =>
  make(message, {"extensions": {"code": "BAD_USER_INPUT"}})
