// Byte-parity guard for the AppSync Events SigV4 signer port.
//
// AppSyncEventsSigner_Ops.signedHeaders is a ReScript port of the hand-rolled
// SigV4 the two stream-relay Lambdas used to carry as inline JS. A one-character
// drift in the canonical request or the signing-key chain silently produces a
// 403 from AppSync and stops live event delivery — invisible until a deploy.
// This asserts the port is byte-identical to the preserved original
// (AppSyncEventsSigner_ParityFixture.mjs) across a range of inputs.

open JestGlobals

type jsCreds = {accessKeyId: string, secretAccessKey: string, sessionToken?: string}
@module("./AppSyncEventsSigner_ParityFixture.mjs")
external signedHeadersJs: (
  ~host: string,
  ~path: string,
  ~body: string,
  ~region: string,
  ~isoNow: string,
  ~creds: jsCreds,
) => dict<string> = "signedHeadersJs"

let get = (d, k) => d->Dict.get(k)->Option.getOr("<missing>")

// Compare the ReScript signer to the JS reference for one input tuple.
let assertParity = (~host, ~path, ~body, ~region, ~isoNow, ~accessKeyId, ~secretAccessKey, ~sessionToken) => {
  let creds: AppSyncEventsSigner_Ops.creds = {accessKeyId, secretAccessKey, sessionToken}
  let mine = AppSyncEventsSigner_Ops.signedHeaders(~host, ~path, ~body, ~region, ~isoNow, ~creds)
  let jsCreds: jsCreds = {accessKeyId, secretAccessKey, sessionToken: ?sessionToken}
  let ref = signedHeadersJs(~host, ~path, ~body, ~region, ~isoNow, ~creds=jsCreds)
  expect(mine->get("Authorization"))->toBe(ref->get("Authorization"))
  expect(mine->get("x-amz-date"))->toBe(ref->get("x-amz-date"))
  expect(mine->get("host"))->toBe(ref->get("host"))
}

describe("AppSyncEventsSigner_Ops.signedHeaders parity with the original JS", () => {
  testSync("session-token present", () => {
    assertParity(
      ~host="abc123.appsync-api.eu-west-1.amazonaws.com",
      ~path="/event",
      ~body=`{"id":"m-1","channel":"/default/Catalog","events":["{\\"position\\":\\"1\\"}"]}`,
      ~region="eu-west-1",
      ~isoNow="2026-07-27T13:45:07.123Z",
      ~accessKeyId="ASIAEXAMPLE",
      ~secretAccessKey="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      ~sessionToken=Some("FQoGZXIvYXdzEXAMPLESESSIONTOKEN=="),
    )
  })

  testSync("no session token (short-lived / role creds without token)", () => {
    assertParity(
      ~host="xyz.appsync-api.us-east-1.amazonaws.com",
      ~path="/event",
      ~body=`{"id":"e-42","channel":"/default/Orders/o-9","events":["{\\"changeKind\\":\\"Added\\"}"]}`,
      ~region="us-east-1",
      ~isoNow="2026-01-02T00:00:00.000Z",
      ~accessKeyId="AKIAEXAMPLE2",
      ~secretAccessKey="anotherSecretKeyValue1234567890abcdef",
      ~sessionToken=None,
    )
  })

  testSync("different region + midnight-adjacent timestamp", () => {
    assertParity(
      ~host="host.appsync-api.ap-southeast-2.amazonaws.com",
      ~path="/event",
      ~body="{}",
      ~region="ap-southeast-2",
      ~isoNow="2026-12-31T23:59:59.999Z",
      ~accessKeyId="AKIA3",
      ~secretAccessKey="k3",
      ~sessionToken=Some("tok3"),
    )
  })
})
