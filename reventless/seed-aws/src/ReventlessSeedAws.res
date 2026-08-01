// AWS `connect` for the seed harness: resolve a deployed stack, read its
// endpoints, and log in with Cognito — returning the same provider-agnostic
// `Seed.connection` a local run produces.
//
// Stack discovery reads the sibling Pulumi project's `Pulumi.<stack>.yaml`
// files (no `pulumi login` needed to list) and calls `pulumi stack output` for
// the chosen one. Endpoints come from the host-shell `config.json` when the
// stack publishes a `hostShellUrl` (the hybrid host-shell shape), or from the
// stack outputs directly otherwise. Login is Cognito USER_PASSWORD_AUTH over a
// plain `fetch` — the host UI client has no secret, so there is no SigV4 and no
// AWS SDK dependency.

open ReventlessSeed

// ── Node bindings ─────────────────────────────────────────────────────────────


type fetchInit = {method: string, headers: dict<string>, body?: string}
type response
@val external fetch: (string, fetchInit) => promise<response> = "fetch"
@send external responseJson: response => promise<JSON.t> = "json"
@get external responseOk: response => bool = "ok"
@get external responseStatus: response => int = "status"

// ── JSON helpers ──────────────────────────────────────────────────────────────

let field = (json: JSON.t, key: string): option<JSON.t> =>
  switch json {
  | Object(obj) => obj->Dict.get(key)
  | _ => None
  }

let asString = (json: JSON.t): option<string> =>
  switch json {
  | String(s) => Some(s)
  | _ => None
  }

// ── Stack discovery ───────────────────────────────────────────────────────────

// Which Pulumi backend the `pulumi` subprocess reads from. When `backend` is
// set it is passed as `PULUMI_BACKEND_URL` on a *copy* of the environment, so
// the operator's persistent `pulumi login` is never mutated — each example pins
// its own backend (core → Pulumi Cloud, a self-hosted app → its S3/… bucket)
// regardless of which backend the CLI is currently logged into. When absent, the
// subprocess inherits the ambient login (or an operator-set PULUMI_BACKEND_URL).
let envForBackend = (backend: option<string>): option<dict<string>> =>
  switch backend {
  | None => None
  | Some(url) =>
    let copy = NodeProcess.env->Dict.toArray->Dict.fromArray
    copy->Dict.set("PULUMI_BACKEND_URL", url)
    Some(copy)
  }

let pulumi = (~projectDir: string, ~backend: option<string>, args: array<string>): string =>
  NodeChildProcess.execFileSync(
    "pulumi",
    args,
    {cwd: projectDir, encoding: "utf8", env: ?envForBackend(backend)},
  )

// Stacks that actually exist in the Pulumi backend for this project — the names
// `pulumi stack output --stack <name>` accepts. A `Pulumi.<stack>.yaml` config
// file alone is NOT a deployed stack, so discovery must ask the backend (via
// `pulumi stack ls`), not the filesystem — otherwise it offers phantom stacks
// that fail with "no stack named …". Empty on any error (pulumi missing / not
// logged in / no stacks), which `resolveStack` reports as "none found".
let deployedStacks = (~projectDir: string, ~backend: option<string>): array<string> =>
  try {
    switch JSON.parseOrThrow(pulumi(~projectDir, ~backend, ["stack", "ls", "--json"])) {
    | JSON.Array(items) => items->Array.filterMap(it => it->field("name")->Option.flatMap(asString))
    | _ => []
    }
  } catch {
  | _ => []
  }

let stackOutputs = (~projectDir: string, ~backend: option<string>, stack: string): JSON.t => {
  let raw = try pulumi(~projectDir, ~backend, ["stack", "output", "--stack", stack, "--json"]) catch {
  | _ =>
    throw(
      Seed.Failed(
        `pulumi stack output --stack ${stack} failed — is pulumi installed, logged in, ` ++
        "and the stack deployed?",
      ),
    )
  }
  try JSON.parseOrThrow(raw) catch {
  | _ => throw(Seed.Failed(`could not parse pulumi stack output for "${stack}"`))
  }
}

let backendNote = (~backend: option<string>): string =>
  switch backend {
  | Some(url) => ` (backend: ${url})`
  | None => ""
  }

let resolveStack = async (~projectDir: string, ~backend: option<string>, ~stack: option<string>): string =>
  switch stack {
  | Some(s) => s
  | None =>
    switch Seed.Prompt.envValue("SEED_STACK") {
    | Some(s) => s
    | None =>
      let stacks = deployedStacks(~projectDir, ~backend)
      if stacks->Array.length == 0 {
        throw(
          Seed.Failed(
            `no deployed Pulumi stacks for this project (\`pulumi stack ls\` is empty in ${projectDir})${backendNote(
                ~backend,
              )}. ` ++
            "A Pulumi.<stack>.yaml config file alone is not a deployed stack — run `pulumi up` " ++
            "first, log in to the backend that holds the stack, or set SEED_STACK to target one.",
          ),
        )
      }
      await Seed.Prompt.select(~title="Stack:", ~options=stacks->Array.map(s => (s, s)))
    }
  }

// ── Endpoints ─────────────────────────────────────────────────────────────────

let fetchConfig = async (hostShellUrl: string): JSON.t => {
  let base = hostShellUrl->String.replaceRegExp(%re("/\/+$/g"), "")
  let url = `${base}/config.json`
  let res = try await fetch(url, {method: "GET", headers: Dict.make()}) catch {
  | _ => throw(Seed.Failed(`cannot reach ${url}`))
  }
  if !(res->responseOk) {
    throw(Seed.Failed(`GET ${url} → HTTP ${(res->responseStatus)->Int.toString}`))
  }
  await res->responseJson
}

// Prefer an explicit env override, else the discovered value, else fail naming
// what is missing.
let resolveField = (~envKey: string, ~fromSource: option<string>, ~human: string): string =>
  switch Seed.Prompt.envValue(envKey) {
  | Some(v) => v
  | None =>
    switch fromSource {
    | Some(v) => v
    | None => throw(Seed.Failed(`deployment is missing ${human} (and ${envKey} is unset)`))
    }
  }

// Which document publishes the deployment's endpoints. A stack that serves a
// host shell publishes them in the shell's `config.json` under the client's key
// names; one that does not publishes them as stack outputs under Pulumi's. The
// two arms name different keys for the same values, which is why this is a
// variant and not a merged lookup.
type source = HostShellConfig(JSON.t) | StackOutputs(JSON.t)

type endpoints = {
  graphql: string,
  cognitoRegion: string,
  cognitoClientId: string,
}

/**
 * The endpoints a source document publishes — pure, so the branch selection and
 * every key it reads can be exercised with synthetic documents.
 *
 * Upload endpoints are no longer resolved here: under route B the seed mints through
 * the domain API's `Upload_Presign` mutation on `graphql`, passing the store per asset,
 * so there is no per-store URL to discover.
 */
let endpointsFrom = (~stack: string, source: source): endpoints =>
  switch source {
  | HostShellConfig(cfg) =>
    let fromCfg = key => cfg->field(key)->Option.flatMap(asString)
    {
      graphql: resolveField(
        ~envKey="REVENTLESS_GRAPHQL_ENDPOINT",
        ~fromSource=fromCfg("apiEndpoint"),
        ~human="apiEndpoint",
      ),
      cognitoRegion: resolveField(
        ~envKey="AWS_REGION",
        ~fromSource=fromCfg("region"),
        ~human="region",
      ),
      cognitoClientId: resolveField(
        ~envKey="COGNITO_CLIENT_ID",
        ~fromSource=fromCfg("cognitoClientId"),
        ~human="cognitoClientId",
      ),
    }
  | StackOutputs(outputs) =>
    let out = key => outputs->field(key)->Option.flatMap(asString)
    {
      graphql: switch (
        Seed.Prompt.envValue("REVENTLESS_GRAPHQL_ENDPOINT"),
        out("domainMergedApiEndpoint"),
        out("domainApiEndpoint"),
      ) {
      | (Some(v), _, _) | (_, Some(v), _) | (_, _, Some(v)) => v
      | _ =>
        throw(
          Seed.Failed(
            `stack "${stack}" exports neither domainMergedApiEndpoint nor domainApiEndpoint`,
          ),
        )
      },
      cognitoRegion: resolveField(
        ~envKey="AWS_REGION",
        ~fromSource=out("cognitoRegion"),
        ~human="cognitoRegion",
      ),
      cognitoClientId: resolveField(
        ~envKey="COGNITO_CLIENT_ID",
        ~fromSource=out("cognitoUserPoolClientId"),
        ~human="cognitoUserPoolClientId",
      ),
    }
  }

let resolveEndpoints = async (
  ~projectDir: string,
  ~backend: option<string>,
  ~stack: string,
): endpoints => {
  let outputs = stackOutputs(~projectDir, ~backend, stack)
  let source = switch outputs->field("hostShellUrl")->Option.flatMap(asString) {
  | Some(hostShellUrl) => HostShellConfig(await fetchConfig(hostShellUrl))
  | None => StackOutputs(outputs)
  }
  endpointsFrom(~stack, source)
}

// ── Cognito login ─────────────────────────────────────────────────────────────

let cognito = (~region: string, ~clientId: string) => async (
  ~username: string,
  ~password: string,
): string => {
  let body = JSON.stringify(
    JSON.Encode.object(
      Dict.fromArray([
        ("AuthFlow", JSON.Encode.string("USER_PASSWORD_AUTH")),
        ("ClientId", JSON.Encode.string(clientId)),
        (
          "AuthParameters",
          JSON.Encode.object(
            Dict.fromArray([
              ("USERNAME", JSON.Encode.string(username)),
              ("PASSWORD", JSON.Encode.string(password)),
            ]),
          ),
        ),
      ]),
    ),
  )
  let headers = Dict.fromArray([
    ("content-type", "application/x-amz-json-1.1"),
    ("x-amz-target", "AWSCognitoIdentityProviderService.InitiateAuth"),
  ])
  let res = try await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
    method: "POST",
    headers,
    body,
  }) catch {
  | _ => throw(Seed.Failed(`cannot reach Cognito in ${region}`))
  }
  let json = await res->responseJson
  if !(res->responseOk) {
    let detail =
      json->field("message")->Option.flatMap(asString)->Option.getOr(JSON.stringify(json))
    throw(
      Seed.Failed(
        `Cognito InitiateAuth failed (HTTP ${(res->responseStatus)->Int.toString}): ${detail}`,
      ),
    )
  }
  switch json->field("ChallengeName")->Option.flatMap(asString) {
  | Some(challenge) =>
    throw(
      Seed.Failed(
        `Cognito returned challenge ${challenge} — set a permanent password first ` ++
        "(aws cognito-idp admin-set-user-password … --permanent).",
      ),
    )
  | None => ()
  }
  switch json
  ->field("AuthenticationResult")
  ->Option.flatMap(ar => ar->field("IdToken"))
  ->Option.flatMap(asString) {
  | Some(token) => token
  | None => throw(Seed.Failed(`Cognito response carried no IdToken: ${JSON.stringify(json)}`))
  }
}

// ── connect ───────────────────────────────────────────────────────────────────

/**
 * A `connect` thunk for a deployed AWS stack, ready to pass to `Seed.Runner.seed`.
 *
 * `projectDir` is where the Pulumi stacks live (relative to the seed's cwd);
 * `stack` fixes the stack, else `SEED_STACK` or a menu chooses it. Resolves the
 * endpoints, then prompts credentials and mints a Cognito id token.
 *
 * `backend` pins the Pulumi backend the stack lives in — Pulumi Cloud
 * (`https://api.pulumi.com`, needs `PULUMI_ACCESS_TOKEN`) for a CI-deployed
 * example, or a self-hosted store (`s3://…?region=…`, needs AWS creds) for a
 * self-hosted app. It is passed to the pulumi subprocess as `PULUMI_BACKEND_URL`
 * on a copy of the environment, so the operator's persistent `pulumi login` is
 * untouched and each example seeds its own backend regardless of the current
 * login. `SEED_PULUMI_BACKEND` overrides it; omit both to use the ambient login.
 */
let connect = (~projectDir: string=".", ~stack=?, ~backend=?, ()): (
  unit => promise<Seed.connection>
) =>
  async () => {
    let backend = switch Seed.Prompt.envValue("SEED_PULUMI_BACKEND") {
    | Some(url) => Some(url)
    | None => backend
    }
    let stackName = await resolveStack(~projectDir, ~backend, ~stack)
    let eps = await resolveEndpoints(~projectDir, ~backend, ~stack=stackName)
    await Seed.Connect.make(
      ~label=stackName,
      ~endpoint=eps.graphql,
      ~login=cognito(~region=eps.cognitoRegion, ~clientId=eps.cognitoClientId),
    )
  }
