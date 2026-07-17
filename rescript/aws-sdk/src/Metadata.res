/** see: https://github.com/smithy-lang/smithy-typescript/blob/75e0125c8d25c4b1002f39d9d0fac7792acc3d43/packages/types/src/response.ts#L4 */
type t = {
  attempts: int,
  cfId: string,
  extendedRequestId: string,
  httpStatusCode: int,
  requestId: string,
  totalRetryDelay: int,
}
