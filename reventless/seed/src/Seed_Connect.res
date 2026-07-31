// Turns endpoints plus a login function into a ready `connection`.
//
// A connection is what a data set seeds against: an authenticated GraphQL
// client, the deployment's upload endpoints (empty when it serves no uploads),
// and a human label for the target. `make` is provider-agnostic — it prompts for
// credentials, calls the supplied `login` to obtain a bearer, and wires it onto
// the client via `useToken`. Where the bearer comes from (a local `/login`
// round-trip, a Cognito id token) is the caller's concern.

open Seed_Types

// `uploadEndpoint` is the legacy single presign service (and the local dev
// server's one upload route); `uploadEndpoints` maps the qualified
// `{plugin}.{store}` of each declared store to its own presign endpoint. Both,
// because a deployment may publish either or both — see `Seed_Upload.endpointFor`
// for the resolution between them.
type connection = {
  client: Seed_Client.t,
  uploadEndpoint: string,
  uploadEndpoints: dict<string>,
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
  ~uploadEndpoint: string,
  ~uploadEndpoints: dict<string>=Dict.make(),
  ~login: (~username: string, ~password: string) => promise<string>,
  ~localDefaults: bool=false,
): connection => {
  // `SEED_SKIP_UPLOADS` forces the connection to carry no upload endpoint at
  // all, so a data set's upload phase no-ops the same way it does when a
  // deployment serves none. Use it to seed domain data fast, or to skip a
  // broken/absent upload path without editing the data set. It is the single
  // knob: an empty `REVENTLESS_UPLOAD_ENDPOINT` env reads as "unset" (falls back
  // to discovery), so this is the reliable way to disable uploads — which means
  // it has to clear the per-store map too, or a declared store keeps uploading
  // through it.
  let skip = Seed_Prompt.envValue("SEED_SKIP_UPLOADS")->Option.isSome
  let uploadEndpoint = skip ? "" : uploadEndpoint
  let uploadEndpoints = skip ? Dict.make() : uploadEndpoints
  let (username, password) = await Seed_Prompt.credentials(~localDefaults)
  let token = await login(~username, ~password)
  let client = Seed_Client.make(~config={endpoint: endpoint})
  client->Seed_Client.useToken(token)
  {client, uploadEndpoint, uploadEndpoints, label}
}

/**
 * The endpoint an asset destined for `store` uploads through, or the reason
 * there is none — the message to report when the upload phase skips.
 *
 * `store` is the qualified `{plugin}.{store}` the asset's field declares, e.g.
 * `"Catalog.productImages"`. Resolution is `Seed_Upload.endpointFor`; naming a
 * store the deployment does not serve falls back to the legacy single service
 * rather than to another store's endpoint.
 */
let uploadEndpointFor = (c: connection, ~store: string): result<string, string> =>
  switch Seed_Upload.endpointFor(
    ~store,
    ~uploadEndpoint=c.uploadEndpoint,
    ~uploadEndpoints=c.uploadEndpoints,
  ) {
  | Some(endpoint) => Ok(endpoint)
  | None => Error(Seed_Upload.unresolvedReason(~store, ~uploadEndpoints=c.uploadEndpoints))
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
 * No per-store map: the local dev server serves every store through its one
 * upload route, so a data set naming a store resolves to that route by the
 * "declares a store with no matching endpoint" row.
 */
let local = (~graphql=?, ~upload=?, ~login=?, ()): (unit => promise<connection>) => {
  let endpoint =
    graphql->Option.getOr(envOr("REVENTLESS_GRAPHQL_ENDPOINT", "http://localhost:4000/graphql"))
  let uploadEndpoint =
    upload->Option.getOr(
      envOr("REVENTLESS_UPLOAD_ENDPOINT", "http://localhost:4000/__inmemory/upload"),
    )
  let loginEndpoint =
    login->Option.getOr(envOr("REVENTLESS_LOGIN_ENDPOINT", "http://localhost:4000/__inmemory/login"))
  () =>
    make(
      ~label="local",
      ~endpoint,
      ~uploadEndpoint,
      ~login=viaLoginEndpoint(~loginEndpoint),
      ~localDefaults=true,
    )
}
