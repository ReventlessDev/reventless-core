# The upload contract: mint, store, serve, release

An object store declared by a `@storageRef` field is filled through a small,
provider-neutral contract. The same shape answers on AWS (a presigned S3 PUT fronted
by CloudFront) and on the local dev platform (a process-local store), so one client
path serves both.

## The four operations

Bytes always travel **direct to the store** — only the presign *metadata* and the
release *decision* go through the GraphQL API.

1. **Mint** — `mutation Upload_Presign(store, fileName, contentType): { uploadUrl, storageRef }`
   The caller names the qualified `{plugin}.{store}` it declares; the service returns a
   short-lived `uploadUrl` (a presigned PUT on AWS; a same-origin `/{prefix}/{key}`
   locally) and the `storageRef` a command will store.
2. **Store** — `PUT uploadUrl` with the raw bytes. Unauthenticated: presigned on AWS,
   open on the local route.
3. **Serve** — the `storageRef` is a same-origin `/{prefix}/{key}` the UI renders
   directly; the store is fronted read-only (CloudFront on AWS, the dev server locally).
4. **Release** — `mutation Upload_Release(store, storageRef): { released, reason }`
   removes an object the caller uploaded but never committed (a replaced pick, a
   cancelled form, a closed tab).

Both mutations live on the **domain** GraphQL API and take its default
`AllowAuthenticated` auth — any authenticated user can mint and release their own
uploads. They are *not* on the Admin-gated platform API, and *not* aggregate/DCB
commands.

## Authentication

There is no anonymous surface. `Upload_Presign`/`Upload_Release` are authenticated by
the API's Cognito authorizer, and the verified caller identity (`sub`) reaches the
resolver. The mint side namespaces every object under the caller's own identity prefix,
`{servedPrefix}/{sub}/…`, which is what makes an ownership check on release possible.

## When a release is allowed

The service deletes an object only when **all** of these hold, and answers with a
distinct, non-leaky reason otherwise:

| Condition | Reason on failure |
|---|---|
| The caller is authenticated | `unauthenticated` |
| The key is under this store's served prefix | `not_in_store` |
| The key is under the caller's own identity prefix | `not_yours` |
| The object is younger than the release window | `too_old` |

The release window defaults to **15 minutes** and is configurable at `make` time
(`~releaseWindowSeconds`). Deleting an already-absent key is **success**, not an error:
release is idempotent, so a client retrying a release it already made is not a failure.

## The guarantee, precisely

**Release is best-effort and time-boxed. It is not a general delete API, and no object
that a committed event references is reachable through it.** An object a command
committed is, in the case that matters, both older than the window and another
identity's, so the age and ownership checks keep it out of reach. What release *cannot*
do is reclaim an object abandoned long ago — that is a sweeper's job (a bucket lifecycle
rule over a mint-time tag), tracked separately.

## Local dev parity

The dev platform has no bucket, so mint/release resolve against a process-local store
(`LocalObjectStore`) and the bytes travel over `PUT`/`GET /{prefix}/{key}` routes on the
dev server. Parity is about the client seeing the **same contract**, not reproducing
AWS's guarantees: the dev store has no identities and no clock, so release enforces only
the *shape* of the rule (the key must be under a served prefix), not the identity/age
conditions.
