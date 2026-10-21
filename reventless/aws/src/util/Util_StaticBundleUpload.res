/** A static bundle uploaded as **one** resource rather than one `BucketObject` per file.

    A per-file resource costs a create or a delete each, and a rebuild renames most hashed
    files, so a bundle of a few hundred files spent most of its deploy creating and deleting
    objects. This resource lists the bucket once, puts what is new or changed sixteen at a time,
    and deletes what is two generations old: a reader with a page open from the previous deploy
    can still load its chunks.

    **Always updated.** `diff_` reports a change on every deploy, and the update compares with
    what the bucket holds (`ListObjectsV2`'s ETag is the MD5 of a single-part upload), so a file
    removed outside Pulumi is put back by the next deploy. Keys this resource never uploaded —
    an explicitly written `config.json`, a served bucket's prefix — are never touched.

    Caveat inherited from every Pulumi dynamic provider: the captured closure is serialised into
    stack state, so the SDK and the Node modules are imported lazily and nothing here captures a
    Pulumi Output. A fix reaches a stack once this resource is next updated, which is every
    deploy. */
let log = ReventlessCore.Logger.fromEnv()

// ── The SDK, imported lazily ─────────────────────────────────────────────────

type s3Client
type buffer

type listInput = {
  @as("Bucket") bucket: string,
  @as("ContinuationToken") continuationToken?: string,
}
type listedObject = {@as("Key") key: string, @as("ETag") etag?: string}
type listResult = {
  @as("Contents") contents?: array<listedObject>,
  @as("IsTruncated") isTruncated?: bool,
  @as("NextContinuationToken") nextContinuationToken?: string,
}
type putInput = {
  @as("Bucket") bucket: string,
  @as("Key") key: string,
  @as("Body") body: buffer,
  @as("ContentType") contentType: string,
  @as("CacheControl") cacheControl: string,
}
type deleteInput = {@as("Bucket") bucket: string, @as("Key") key: string}

type listCmd
type putCmd
type deleteCmd

type sdkModule = {
  @as("S3Client") clientCtor: unknown,
  @as("ListObjectsV2Command") listCtor: unknown,
  @as("PutObjectCommand") putCtor: unknown,
  @as("DeleteObjectCommand") deleteCtor: unknown,
}

@module("./Util_LogGroup_Adopting_Js.mjs") external newCommand: ('ctor, 'arg) => 'cmd = "newCommand"
@module("./Util_LogGroup_Adopting_Js.mjs") external newClient: 'ctor => s3Client = "newClient"

@send external sendList: (s3Client, listCmd) => promise<listResult> = "send"
@send external sendPut: (s3Client, putCmd) => promise<unit> = "send"
@send external sendDelete: (s3Client, deleteCmd) => promise<unit> = "send"

type fsModule = {readFile: string => promise<buffer>}
type hash
type cryptoModule = {createHash: string => hash}
@send external hashUpdate: (hash, buffer) => hash = "update"
@send external hashDigest: (hash, string) => string = "digest"

// Emitted as a literal `import("...")`, so the serialiser does not capture the modules.
@val external importSdk: string => promise<sdkModule> = "import"
@val external importFs: string => promise<fsModule> = "import"
@val external importCrypto: string => promise<cryptoModule> = "import"

let _client: ref<option<(sdkModule, s3Client)>> = ref(None)

let client = async (): (sdkModule, s3Client) =>
  switch _client.contents {
  | Some(c) => c
  | None =>
    let sdk = await importSdk("@aws-sdk/client-s3")
    let c = (sdk, newClient(sdk.clientCtor))
    _client.contents = Some(c)
    c
  }

// ── The resource ─────────────────────────────────────────────────────────────

/** One file of the bundle: its key, read from `dir ++ "/" ++ key` at upload time. */
type file = {key: string, contentType: string, cacheControl: string}

type providerInputs = {bucket: string, dir: string, files: array<file>}

/** `keys` are this deploy's, `previousKeys` the deploy's before; a key in neither goes. */
type outs = {
  bucket: Nullable.t<string>,
  keys: Nullable.t<array<string>>,
  previousKeys: Nullable.t<array<string>>,
  uploaded: Nullable.t<int>,
}

type createResultOut = {id: string, outs: outs}
type updateResultOut = {outs: outs}
type diffResult = {changes: bool, replaces: array<string>, deleteBeforeReplace: bool}

/** What the bucket holds, key to ETag (quotes stripped). */
let listed = async (~bucket: string): dict<string> => {
  let (sdk, s3) = await client()
  let found = Dict.make()
  let rec page = async (token: option<string>) => {
    let result = await s3->sendList(newCommand(sdk.listCtor, {bucket, continuationToken: ?token}))
    result.contents
    ->Option.getOr([])
    ->Array.forEach(o =>
      found->Dict.set(o.key, o.etag->Option.getOr("")->String.replaceAll("\"", ""))
    )
    switch (result.isTruncated, result.nextContinuationToken) {
    | (Some(true), Some(next)) => await page(Some(next))
    | _ => ()
    }
  }
  await page(None)
  found
}

/** Runs `work` over `items`, `limit` at a time. */
let inBatches = async (items: array<'a>, ~limit: int, work: 'a => promise<unit>): unit => {
  let rec from = async (start: int) =>
    if start < Array.length(items) {
      let _ = await Promise.all(items->Array.slice(~start, ~end=start + limit)->Array.map(work))
      await from(start + limit)
    }
  await from(0)
}

/** Puts every file the bucket lacks or holds different bytes for; returns how many. */
let upload = async ({bucket, dir, files}: providerInputs): int => {
  let (sdk, s3) = await client()
  let fs = await importFs("node:fs/promises")
  let crypto = await importCrypto("node:crypto")
  let held = await listed(~bucket)
  let count = ref(0)
  await files->inBatches(~limit=16, async f => {
    let body = await fs.readFile(dir ++ "/" ++ f.key)
    let md5 = crypto.createHash("md5")->hashUpdate(body)->hashDigest("hex")
    if held->Dict.get(f.key) != Some(md5) {
      await s3->sendPut(
        newCommand(
          sdk.putCtor,
          {bucket, key: f.key, body, contentType: f.contentType, cacheControl: f.cacheControl},
        ),
      )
      count := count.contents + 1
    }
  })
  log.info(
    ~comp="Util_StaticBundleUpload",
    `${bucket}: ${Int.toString(count.contents)} of ${Int.toString(
        Array.length(files),
      )} files uploaded`,
  )
  count.contents
}

let remove = async (~bucket: string, keys: array<string>): unit => {
  let (sdk, s3) = await client()
  await keys->inBatches(~limit=16, async key =>
    await s3->sendDelete(newCommand(sdk.deleteCtor, {bucket, key}))
  )
}

let keysOf = (inputs: providerInputs) => inputs.files->Array.map(f => f.key)

/** The keys an update deletes: last deploy's previous ones that neither this deploy nor the
    last one names. */
let staleKeys = (
  ~current: array<string>,
  ~previous: array<string>,
  ~beforePrevious: array<string>,
) =>
  beforePrevious->Array.filter(k => !(current->Array.includes(k)) && !(previous->Array.includes(k)))

let create = async (inputs: providerInputs): createResultOut => {
  let uploaded = await upload(inputs)
  {
    id: inputs.bucket,
    outs: {
      bucket: Nullable.make(inputs.bucket),
      keys: Nullable.make(keysOf(inputs)),
      previousKeys: Nullable.make([]),
      uploaded: Nullable.make(uploaded),
    },
  }
}

let update = async (_id: string, olds: outs, news: providerInputs): updateResultOut => {
  let uploaded = await upload(news)
  let current = keysOf(news)
  let previous = olds.keys->Nullable.toOption->Option.getOr([])
  let stale = staleKeys(
    ~current,
    ~previous,
    ~beforePrevious=olds.previousKeys->Nullable.toOption->Option.getOr([]),
  )
  await remove(~bucket=news.bucket, stale)
  {
    outs: {
      bucket: Nullable.make(news.bucket),
      keys: Nullable.make(current),
      previousKeys: Nullable.make(previous),
      uploaded: Nullable.make(uploaded),
    },
  }
}

/** Takes its files with it: the ones it uploaded in its last two deploys. */
let delete_ = async (_id: string, olds: outs): unit =>
  switch olds.bucket->Nullable.toOption {
  | None => ()
  | Some(bucket) =>
    let keys = Array.concat(
      olds.keys->Nullable.toOption->Option.getOr([]),
      olds.previousKeys->Nullable.toOption->Option.getOr([]),
    )
    await remove(~bucket, keys->Set.fromArray->Set.values->Iterator.toArray)
  }

let diff_ = (_id: string, olds: outs, news: providerInputs): diffResult => {
  changes: true,
  replaces: olds.bucket->Nullable.toOption != Some(news.bucket) ? ["bucket"] : [],
  deleteBeforeReplace: false,
}

let provider = {
  "create": create,
  "update": update,
  "delete": delete_,
  "diff": diff_,
}

// ── Pulumi dynamic resource binding ──────────────────────────────────────────

type t = {uploaded: Pulumi.Output.t<int>}

type constructorProps = {
  bucket: Pulumi.Input.t<string>,
  dir: string,
  files: array<file>,
}

/** Output-only properties are declared `undefined`, Pulumi's way to register them. */
type resourceProps = {
  bucket: Pulumi.Input.t<string>,
  dir: string,
  files: array<file>,
  keys: Nullable.t<array<string>>,
  previousKeys: Nullable.t<array<string>>,
  uploaded: Nullable.t<int>,
}

@module("@pulumi/pulumi/dynamic/index.js") @new
external _newResource: ('provider, string, 'props, Pulumi.CustomResourceOptions.t) => t = "Resource"

let make = (~name: string, ~props: constructorProps): t =>
  _newResource(
    provider,
    name,
    {
      bucket: props.bucket,
      dir: props.dir,
      files: props.files,
      keys: Nullable.undefined,
      previousKeys: Nullable.undefined,
      uploaded: Nullable.undefined,
    },
    {},
  )
