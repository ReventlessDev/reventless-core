// The resolver code of the narrow API for visitors: what differs from the plugin
// API's is that each request says it is a visitor's and from which address, so
// the function behind it counts it per door and source.

module Functions = PulumiAws.AppSync.Resolver.Functions

/** The caller's address as AppSync reports it: the forwarded-for header, whose
    first entry is the caller's. */
let sourceAddress = "ctx.request?.headers?.['x-forwarded-for'] ?? null"

/** A door: the plugin API's invocation, marked as a visitor's. */
let invokeDoor = (fieldName: string) =>
  `${Functions.importUtil}
export function request(ctx) {
  return {
    operation: 'Invoke',
    payload: {
      __inboundTranslation: true,
      visitor: true,
      sourceAddress: ${sourceAddress},
      fieldName: '${fieldName}',
      arguments: ctx.args,
      identity: null
    }
  };
}
${Functions.resultResponseCode}
`->Pulumi.Input.make

/** The step before a view's read: asks the function whether one more request
    from this source reaches `door`, and stops the request where it does not. An
    error rather than an empty answer: an empty page would read as "nothing to
    say", and a visitor asking which roles are open would be told all of them. */
let limitStep = (door: string) =>
  `${Functions.importUtil}
export function request(ctx) {
  return {
    operation: 'Invoke',
    payload: { __visitorLimit: true, door: '${door}', sourceAddress: ${sourceAddress} }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  if (!ctx.result || ctx.result.admitted !== true) {
    util.error('too many requests from this source; retry later', 'Throttled');
  }
  return ctx.result;
}
`->Pulumi.Input.make
