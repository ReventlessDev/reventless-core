// Golden reference for the AppSync Events SigV4 signer parity test.
//
// This is the EXACT hand-rolled `signedHeaders` that lived in the inline JS
// handler strings of EventLogSubscription_AppSync.res and StateTopic_AppSync.res
// before those handlers were ported to ReScript (AppSyncEventsSigner_Ops.res).
// Preserved verbatim except: `new Date()` becomes `new Date(isoNow)` and the
// credentials are passed in rather than read from process.env — so the signer is
// deterministic and comparable. AppSyncEventsSigner_OpsTest asserts the ReScript
// port produces byte-identical output to this reference, guarding against any
// drift in the canonical-request construction or the HMAC signing-key chain.

import { createHmac, createHash } from "node:crypto";

function sha256hex(data) {
  return createHash("sha256").update(typeof data === "string" ? data : JSON.stringify(data)).digest("hex");
}
function hmacBuf(key, data) {
  return createHmac("sha256", key).update(data).digest();
}

export function signedHeadersJs(host, path, body, region, isoNow, creds) {
  const { accessKeyId, secretAccessKey, sessionToken } = creds;
  const now = new Date(isoNow);
  const amzDate = now.toISOString().replace(/[:\-]|\..../g, "").slice(0, 15) + "Z";
  const dateStamp = now.toISOString().slice(0, 10).replace(/-/g, "");
  const headers = { host, "x-amz-date": amzDate, ...(sessionToken ? { "x-amz-security-token": sessionToken } : {}) };
  const canonH = Object.entries(headers).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}:${v}\n`).join("");
  const signH = Object.keys(headers).sort().join(";");
  const cr = ["POST", path, "", canonH, signH, sha256hex(body)].join("\n");
  const scope = `${dateStamp}/${region}/appsync/aws4_request`;
  const sts = ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(cr)].join("\n");
  const kDate = hmacBuf("AWS4" + secretAccessKey, dateStamp);
  const kSigning = hmacBuf(hmacBuf(hmacBuf(kDate, region), "appsync"), "aws4_request");
  const sig = createHmac("sha256", kSigning).update(sts).digest("hex");
  return { ...headers, Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signH}, Signature=${sig}` };
}
