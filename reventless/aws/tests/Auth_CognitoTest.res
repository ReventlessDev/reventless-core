// Auth_Cognito unit tests — runtime identity extraction matrix.
// Deploy-time `make` (Pulumi UserPool + UserPoolClient construction) is
// exercised by `pulumi up` in Stage C; not covered here.

open JestGlobals

// ── Helpers ───────────────────────────────────────────────────────────────

let buildContext = (
  headers: array<(string, string)>,
): ReventlessCore.Auth_Adapter.requestContext => {
  headers: Dict.fromArray(headers),
}

@val external btoa: string => string = "btoa"
let b64urlEncode = (s: string): string =>
  btoa(s)
  ->String.replaceAll("+", "-")
  ->String.replaceAll("/", "_")
  ->String.replaceAll("=", "")

// Build a JWT-shaped string with a real (non-verified) payload. Signature is
// a placeholder — Auth_Cognito.authenticate does not verify, AppSync does
// upstream of the resolver.
let buildJwt = (claims: dict<JSON.t>): string => {
  let header = b64urlEncode(`{"alg":"HS256","typ":"JWT"}`)
  let payload = b64urlEncode(claims->JSON.Encode.object->JSON.stringify)
  let sig = "sig"
  `${header}.${payload}.${sig}`
}

// ── authenticate (header-driven path) ─────────────────────────────────────

describe("Auth_Cognito.authenticate", () => {
  testAsync("no Authorization header → Anonymous", async () => {
    let r = await Auth_Cognito.authenticate(buildContext([]))
    switch r {
    | Anonymous => ()
    | _ => JsError.throwWithMessage("expected Anonymous")
    }
  })

  testAsync("non-Bearer Authorization header → Anonymous", async () => {
    let r = await Auth_Cognito.authenticate(
      buildContext([("authorization", "Basic dXNlcjpwYXNz")]),
    )
    switch r {
    | Anonymous => ()
    | _ => JsError.throwWithMessage("expected Anonymous")
    }
  })

  testAsync("malformed Bearer token → AuthError", async () => {
    let r = await Auth_Cognito.authenticate(
      buildContext([("authorization", "Bearer not-a-jwt")]),
    )
    switch r {
    | AuthError(_) => ()
    | _ => JsError.throwWithMessage("expected AuthError")
    }
  })

  testAsync("valid Cognito JWT → Authenticated with sub/groups/username", async () => {
    let claims = Dict.fromArray([
      ("sub", JSON.Encode.string("c3741234-aaaa-bbbb-cccc-ddddeeee1234")),
      ("cognito:username", JSON.Encode.string("alice@example.com")),
      (
        "cognito:groups",
        ["Admin", "User"]->Array.map(JSON.Encode.string)->JSON.Encode.array,
      ),
    ])
    let token = buildJwt(claims)
    let r = await Auth_Cognito.authenticate(
      buildContext([("authorization", "Bearer " ++ token)]),
    )
    switch r {
    | Authenticated(identity) =>
      expect(identity.userId)->toBe("c3741234-aaaa-bbbb-cccc-ddddeeee1234")
      expect(identity.username)->toBe("alice@example.com")
      expect(identity.groups)->toEqual(["Admin", "User"])
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })

  testAsync("JWT without cognito:groups → empty groups", async () => {
    let claims = Dict.fromArray([
      ("sub", JSON.Encode.string("user-1")),
      ("cognito:username", JSON.Encode.string("bob")),
    ])
    let token = buildJwt(claims)
    let r = await Auth_Cognito.authenticate(
      buildContext([("authorization", "Bearer " ++ token)]),
    )
    switch r {
    | Authenticated(identity) =>
      expect(identity.groups)->toEqual([])
      expect(identity.username)->toBe("bob")
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })

  testAsync("header lookup is case-insensitive (Authorization)", async () => {
    let claims = Dict.fromArray([
      ("sub", JSON.Encode.string("user-mixed-case")),
    ])
    let token = buildJwt(claims)
    let r = await Auth_Cognito.authenticate(
      buildContext([("Authorization", "Bearer " ++ token)]),
    )
    switch r {
    | Authenticated(identity) => expect(identity.userId)->toBe("user-mixed-case")
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })
})

// ── fromAppSyncIdentity (resolver-event path) ─────────────────────────────

describe("Auth_Cognito.fromAppSyncIdentity", () => {
  testSync("None → Anonymous", () => {
    switch Auth_Cognito.fromAppSyncIdentity(None) {
    | Anonymous => ()
    | _ => JsError.throwWithMessage("expected Anonymous")
    }
  })

  testSync("Cognito identity: sub + claims.cognito:groups → Authenticated with Cognito provider", () => {
    let claims = Dict.fromArray([
      ("cognito:username", JSON.Encode.string("alice@example.com")),
      (
        "cognito:groups",
        ["Admin"]->Array.map(JSON.Encode.string)->JSON.Encode.array,
      ),
    ])
    let id: Auth_Cognito.appSyncIdentity = {
      sub: "c3741234-aaaa",
      username: "alice@example.com",
      claims,
    }
    switch Auth_Cognito.fromAppSyncIdentity(Some(id)) {
    | Authenticated(identity) =>
      expect(identity.userId)->toBe("c3741234-aaaa")
      expect(identity.username)->toBe("alice@example.com")
      expect(identity.groups)->toEqual(["Admin"])
      switch identity.provider {
      | Cognito => ()
      | _ => JsError.throwWithMessage("expected Cognito provider")
      }
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })

  testSync("Cognito identity: missing claims.cognito:groups → empty groups", () => {
    let id: Auth_Cognito.appSyncIdentity = {
      sub: "user-no-groups",
      claims: Dict.make(),
    }
    switch Auth_Cognito.fromAppSyncIdentity(Some(id)) {
    | Authenticated(identity) =>
      expect(identity.groups)->toEqual([])
      // username falls back to sub when no claim is present
      expect(identity.username)->toBe("user-no-groups")
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })

  testSync("IAM identity: no sub but userArn present → Custom(\"aws-iam\") provider", () => {
    let id: Auth_Cognito.appSyncIdentity = {
      userArn: "arn:aws:iam::123456789012:role/heartbeat-lambda",
      accountId: "123456789012",
      username: "heartbeat-lambda",
    }
    switch Auth_Cognito.fromAppSyncIdentity(Some(id)) {
    | Authenticated(identity) =>
      expect(identity.userId)->toBe("arn:aws:iam::123456789012:role/heartbeat-lambda")
      expect(identity.username)->toBe("heartbeat-lambda")
      expect(identity.groups)->toEqual([])
      switch identity.provider {
      | Custom("aws-iam") => ()
      | _ => JsError.throwWithMessage("expected Custom(\"aws-iam\") provider")
      }
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })

  testSync("IAM identity: userArn alone (no username) → username falls back to ARN", () => {
    let id: Auth_Cognito.appSyncIdentity = {
      userArn: "arn:aws:iam::123:role/x",
    }
    switch Auth_Cognito.fromAppSyncIdentity(Some(id)) {
    | Authenticated(identity) => expect(identity.username)->toBe("arn:aws:iam::123:role/x")
    | _ => JsError.throwWithMessage("expected Authenticated")
    }
  })

  testSync("Neither sub nor userArn → Anonymous", () => {
    let id: Auth_Cognito.appSyncIdentity = {accountId: "123"}
    switch Auth_Cognito.fromAppSyncIdentity(Some(id)) {
    | Anonymous => ()
    | _ => JsError.throwWithMessage("expected Anonymous")
    }
  })
})
