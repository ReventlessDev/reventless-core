// Direct-to-S3 upload presign service behind a public Lambda Function URL.
//
// Deploy-time: `make` provisions a CallbackFunction (handler closure serialized
// by Pulumi), an IAM execution role scoped to `s3:PutObject` on the target
// bucket, and a Function URL (no auth) so a browser can request a presigned PUT.
//
// Runtime: `handlePresign` reads a JSON body `{fileName, contentType}`, derives
// a target key `uploads/<identity?>/<uuid>/<fileName>`, presigns a PUT to the
// bucket named in `UPLOAD_BUCKET` (expires in 300s), and returns
// `{uploadUrl, storageRef}`. A Bearer token, when present, is decoded (no
// signature verification here — that is the auth layer's job) and its `sub`
// namespaces the key; anonymous callers are still served for the demo.

open PulumiAws

// ── AWS SDK v3 bindings ─────────────────────────────────────────────────────

type s3Client

type putObjectInput = {
  @as("Bucket") bucket: string,
  @as("Key") key: string,
  @as("ContentType") contentType?: string,
}
type putObjectCommand

@module("@aws-sdk/client-s3") @new external makeS3Client: unit => s3Client = "S3Client"

@module("@aws-sdk/client-s3") @new
external makePutObjectCommand: putObjectInput => putObjectCommand = "PutObjectCommand"

type presignOptions = {expiresIn: int}

@module("@aws-sdk/s3-request-presigner")
external getSignedUrl: (s3Client, putObjectCommand, presignOptions) => promise<string> =
  "getSignedUrl"

// ── Function URL event / response shapes (payload format 2.0) ────────────────

type functionUrlEvent = {
  body?: string,
  headers?: dict<string>,
}

type response = {
  statusCode: int,
  headers?: dict<string>,
  body: string,
}

let getEnv: string => option<string> = %raw(`
  function(k) { var v = process.env[k]; return (v === undefined || v === null || v === "") ? undefined : v; }
`)

// Node 22 exposes globalThis.crypto.randomUUID; fall back to node:crypto.
let genUuid: unit => string = %raw(`
  function() {
    return (globalThis.crypto && globalThis.crypto.randomUUID)
      ? globalThis.crypto.randomUUID()
      : require("crypto").randomUUID();
  }
`)

// Decode a JWT payload's `sub` claim without verifying the signature (the auth
// layer verifies; here we only namespace the storage key).
let decodeJwtSub: string => option<string> = %raw(`
  function(header) {
    try {
      var token = header.indexOf("Bearer ") === 0 ? header.slice(7) : header;
      var parts = token.split(".");
      if (parts.length < 2) return undefined;
      var base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
      var json = Buffer.from(base64, "base64").toString("utf8");
      var claims = JSON.parse(json);
      return (claims && claims.sub) ? String(claims.sub) : undefined;
    } catch (_) { return undefined; }
  }
`)

let corsHeaders = () =>
  Dict.fromArray([
    ("content-type", "application/json"),
    ("access-control-allow-origin", "*"),
    ("access-control-allow-methods", "POST,OPTIONS"),
    ("access-control-allow-headers", "*"),
  ])

// Key prefix from the caller identity when a Bearer token is present.
let identityPrefix = (event: functionUrlEvent): string => {
  let authHeader =
    event.headers->Option.flatMap(h =>
      h->Dict.get("authorization")->Option.orElse(h->Dict.get("Authorization"))
    )
  switch authHeader->Option.flatMap(decodeJwtSub) {
  | Some(sub) => `${sub}/`
  | None => ""
  }
}

// ── Runtime handler ─────────────────────────────────────────────────────────

let handlePresign = async (event: functionUrlEvent, _context: Lambda.context): response => {
  try {
    let bucket = getEnv("UPLOAD_BUCKET")->Option.getOr("")
    let parsed =
      event.body
      ->Option.getOr("{}")
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.getOr(Dict.make())
    let fileName =
      parsed->Dict.get("fileName")->Option.flatMap(JSON.Decode.string)->Option.getOr("upload")
    let contentType = parsed->Dict.get("contentType")->Option.flatMap(JSON.Decode.string)

    // The object key doubles as the served path segment: it is rooted at the
    // served prefix (`SERVED_PREFIX`, e.g. `uploads`) so the CloudFront
    // `{prefix}/*` behavior fronts it. Callers PUT to this exact key.
    let servedPrefix = getEnv("SERVED_PREFIX")->Option.getOr("uploads")
    let key = `${servedPrefix}/${identityPrefix(event)}${genUuid()}/${fileName}`
    let client = makeS3Client()
    let command = makePutObjectCommand({bucket, key, contentType: ?contentType})
    let uploadUrl = await getSignedUrl(client, command, {expiresIn: 300})

    // The stored ref is a same-origin relative URL `/{key}`: the served bucket is
    // fronted read-only by the UI's own CloudFront distribution under
    // `{prefix}/*`, so a command stores this directly-renderable value and an
    // `image`-semantic field thumbnails it with no post-processing and no public
    // bucket. See [docs/plans/done/ui-served-buckets.md].
    let storageRef = `/${key}`

    {
      statusCode: 200,
      headers: corsHeaders(),
      body: Dict.fromArray([
        ("uploadUrl", JSON.Encode.string(uploadUrl)),
        ("storageRef", JSON.Encode.string(storageRef)),
      ])
      ->JSON.Encode.object
      ->JSON.stringify,
    }
  } catch {
  | _ => {
      statusCode: 400,
      headers: corsHeaders(),
      body: Dict.fromArray([("error", JSON.Encode.string("presign_failed"))])
      ->JSON.Encode.object
      ->JSON.stringify,
    }
  }
}

// ── Deploy-time factory ─────────────────────────────────────────────────────

type serviceOutputs = {
  url: Pulumi.Output.t<string>,
  resources: array<Pulumi.Output.t<string>>,
}

let make = (
  ~bucketName: Pulumi.Input.t<string>,
  ~corsOrigins: array<string>=["*"],
  // Prefix the presigned object keys are rooted at; must match the served
  // bucket's CloudFront `{prefix}/*` behavior so the returned `/{key}` ref
  // resolves. Defaults to `uploads`.
  ~servedPrefix: string="uploads",
  ~opts=?,
): serviceOutputs => {
  let serviceName = "UploadPresignService"
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=serviceName,
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=serviceName,
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts?,
  )

  // Least-privilege: PutObject on any key under the target bucket.
  let _policy =
    bucketName
    ->Pulumi.Output.fromInput
    ->Pulumi.Output.apply(b => {
      let arn = `arn:aws:s3:::${b}/*`
      let _ = IAM.RolePolicy.make(
        ~name=`${serviceName}Policy`,
        ~args={
          policy: PolicyDocument.make(
            ~id=`${serviceName}Policy`,
            ~statements=[
              {
                sid: "AllowUploadPut",
                effect: Allow,
                actions: Action("s3:PutObject"),
                resources: Resource(arn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts?,
      )
    })

  let environment: Lambda.CallbackFunction.Args.functionEnvironment = {
    // CallbackFunction under-types env values as `dict<string>`; Pulumi resolves
    // Output-valued variables at deploy time, so bridge the Input here.
    variables: Dict.fromArray([
      ("UPLOAD_BUCKET", bucketName),
      ("SERVED_PREFIX", Pulumi.Input.make(servedPrefix)),
    ])->Obj.magic,
  }

  let lambda = Lambda.CallbackFunction.make(
    ~name=serviceName,
    ~args=Lambda.CallbackFunction.Args.make(
      ~callback=handlePresign,
      ~role=lambdaRole,
      ~environment,
      ~timeout=30->Pulumi.Input.make,
      ~tags=AWS.Tags.make(
        ~name=serviceName,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Runtime,
        ~scope=Platform,
      ),
    ),
    ~opts?,
  )

  let functionUrl = FunctionUrl.make(
    ~name=`${serviceName}Url`,
    ~args={
      authorizationType: FunctionUrl.None,
      functionName: lambda.name->Pulumi.Output.asInput,
      cors: (
        {
          allowMethods: ["POST"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
          allowOrigins: corsOrigins->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
          allowHeaders: ["*"]->Array.map(Pulumi.Input.make)->Pulumi.Input.make,
        }: FunctionUrl.cors
      )->Pulumi.Input.make,
    },
    ~opts?,
  )

  {
    url: functionUrl.functionUrl,
    resources: [lambda.arn, functionUrl.functionArn],
  }
}
