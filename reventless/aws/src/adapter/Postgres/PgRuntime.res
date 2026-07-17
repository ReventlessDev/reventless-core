/** Cold-start Postgres connectivity for deployed Lambdas.

  Given a resolved `PgConnection.connectionConfig` (injected into the handler env
  at deploy time), this resolves the RDS-managed master password from Secrets
  Manager and builds **one pg pool per container**, memoized by secret ARN.

  Rotation-safe by construction: the pool is created with a *password provider*,
  which pg invokes each time it opens a physical connection — so a rotated secret
  is picked up on the next new connection. The fetched secret is cached per ARN
  (as a promise) to avoid a Secrets Manager round trip on every connection; a
  password rotation surfaces as auth failures that recycle the container, after
  which the next cold start re-fetches. */

/** RDS-managed master secret payload (`{username, password}` JSON). We only need
  the password here — the username is carried on `connectionConfig` (deploy-time
  known) so the pool can be constructed without first awaiting the secret. */
let passwordFromSecret = async (secretArn: string): string => {
  let out =
    await {AwsSdk.SecretsManager.GetSecretValueCommand.secretId: secretArn}
    ->AwsSdk.SecretsManager.GetSecretValueCommand.make
    ->AwsSdk.SecretsManager.GetSecretValueCommand.send
  switch out.secretString {
  | Some(str) =>
    switch str->JSON.parseOrThrow->JSON.Decode.object {
    | Some(obj) =>
      switch obj->Dict.get("password")->Option.flatMap(JSON.Decode.string) {
      | Some(password) => password
      | None => JsError.throwWithMessage("Secrets Manager secret has no `password` field")
      }
    | None => JsError.throwWithMessage("Secrets Manager secret is not a JSON object")
    }
  | None =>
    JsError.throwWithMessage(`Secrets Manager secret ${secretArn} has no SecretString`)
  }
}

// Cache the in-flight/settled password fetch per ARN so pg's per-connection
// provider doesn't hit Secrets Manager on every physical connection.
let passwordCache: dict<promise<string>> = Dict.make()

let cachedPassword = (secretArn: string): promise<string> =>
  switch passwordCache->Dict.get(secretArn) {
  | Some(p) => p
  | None =>
    let p = passwordFromSecret(secretArn)
    passwordCache->Dict.set(secretArn, p)
    p
  }

// One pool per secret ARN for the life of the container.
let poolCache: dict<ReventlessPostgres.PgDriver.pool> = Dict.make()

/** The container-lifetime pool for the given connection config, built on first
  use. pg pools connect lazily, so this is cheap until the first query. */
let poolFor = (config: PgConnection.connectionConfig): ReventlessPostgres.PgDriver.pool =>
  switch poolCache->Dict.get(config.secretArn) {
  | Some(pool) => pool
  | None =>
    let pool = ReventlessPostgres.PgDriver.makePool({
      host: config.host,
      port: config.port,
      database: config.database,
      user: config.username,
      password: () => cachedPassword(config.secretArn),
      // RDS PG15+ defaults to rds.force_ssl=1. Encrypt without CA verification
      // for v1; pin the RDS CA bundle as a hardening follow-up.
      ssl: {rejectUnauthorized: false},
    })
    poolCache->Dict.set(config.secretArn, pool)
    pool
  }
