// Turns endpoints plus a login function into a ready `connection`.
//
// A connection is what a data set seeds against: an authenticated GraphQL
// client, the deployment's upload endpoints (empty when it serves no uploads),
// and a human label for the target. `make` is provider-agnostic — it prompts for
// credentials, calls the supplied `login` to obtain a bearer, and wires it onto
// the client via `useToken`. Where the bearer comes from (a local `/login`
// round-trip, a Cognito id token) is the caller's concern.

open Seed_Types

// Under route B the client mints uploads through the domain API's `Upload_Presign`
// mutation (authenticated by the same bearer as commands), so a connection needs no
// upload endpoint — just the authenticated client and whether uploads are skipped this
// run (`SEED_SKIP_UPLOADS`). Which store an asset uploads into is the caller's `~store`.
type connection = {
  client: Seed_Client.t,
  uploadsSkipped: bool,
  label: string,
}

/**
 * Prompts for credentials, calls `login` to mint a bearer, and returns a
 * connection with that bearer already applied. `login` returns the bearer so a
 * single `useToken` path serves every provider.
 */
let make = async (
  ~label: string,
  ~endpoint: string,
  ~login: (~username: string, ~password: string) => promise<string>,
  ~localDefaults: bool=false,
): connection => {
  // `SEED_SKIP_UPLOADS` forces the upload phase to no-op — seed domain data fast, or
  // skip a broken/absent upload path without editing the data set. The data set reads
  // `connection.uploadsSkipped` and reports the skip.
  let uploadsSkipped = Seed_Upload.uploadsSkipped()
  let (username, password) = await Seed_Prompt.credentials(~localDefaults)
  let token = await login(~username, ~password)
  let client = Seed_Client.make(~config={endpoint: endpoint})
  client->Seed_Client.useToken(token)
  {client, uploadsSkipped, label}
}

/**
 * A login function backed by an HTTP login endpoint (the local dev
 * `/__inmemory/login` shape: POST `{username, password}` → `{token}`). Reuses
 * `Seed_Client.login` but hands the token back for `useToken`.
 */
let viaLoginEndpoint = (~loginEndpoint: string) => async (
  ~username: string,
  ~password: string,
): string => {
  let client = Seed_Client.make(
    ~config={endpoint: loginEndpoint, loginEndpoint, username, password},
  )
  await Seed_Client.login(client)
  switch Seed_Client.currentToken(client) {
  | Some(token) => token
  | None => throw(Failed(`login at ${loginEndpoint} returned no token`))
  }
}

let envOr = (key: string, fallback: string): string =>
  Seed_Prompt.envValue(key)->Option.getOr(fallback)

/**
 * A ready `connect` thunk for the local dev platform, with the localhost
 * defaults baked in and overridable per endpoint (arg, then env var, then
 * default). Empty input at the credential prompt falls back to `admin`/`admin`.
 *
 * No upload endpoint: uploads mint through the domain API's `Upload_Presign` mutation
 * on the same `graphql` endpoint, with the store passed per asset.
 */
let local = (~graphql=?, ~login=?, ()): (unit => promise<connection>) => {
  let endpoint =
    graphql->Option.getOr(envOr("REVENTLESS_GRAPHQL_ENDPOINT", "http://localhost:4000/graphql"))
  let loginEndpoint =
    login->Option.getOr(envOr("REVENTLESS_LOGIN_ENDPOINT", "http://localhost:4000/__inmemory/login"))
  () =>
    make(
      ~label="local",
      ~endpoint,
      ~login=viaLoginEndpoint(~loginEndpoint),
      ~localDefaults=true,
    )
}
