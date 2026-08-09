// Offline reconciliation for a deployed object store: what is in the store,
// what the event log actually references, and the difference between them.
//
// This is the evidence that makes enabling a store's expiry rule safe — the one
// mechanism that can *prove* an object is unreferenced, which is why it is an
// operator-run report and not a request handler. Read-only from start to finish:
// it lists, it scans, it prints. Nothing here deletes anything, and it needs
// none of the reset tool's fail-closed gates because there is nothing to fail
// closed about.
//
// The question it answers is the one the lifecycle rule is about to answer
// destructively: **is every object still tagged pending genuinely unreferenced?**
// A single row in the "referenced but still tagged" section is a bug caught on
// a report instead of on a page.
//
// ## Why it does not read the `@storageRef` declarations
//
// The claim component is declaration-driven: it untags the refs that annotated
// fields carry. If reconciliation read the same declarations it would inherit
// the same blind spot, and the two would agree precisely where they were both
// wrong — a field nobody annotated holds a ref, the claimer never strips its
// tag, and a report derived from the same list would call the object
// unreferenced too. So this walks each event's payload for *any* string under
// the store's prefix.
//
// That is deliberately generous, and generous is the safe direction here: it can
// only ever move an object from "unreferenced" to "referenced", never the
// reverse. An unannotated ref therefore shows up exactly where it should — in
// the referenced-but-tagged section, as the thing to fix before turning expiry
// on.
//
// ## Cost
//
// A full scan of every event log table and a tagging read per object. Minutes on
// a demo store, longer on a real one, and both are fine for something an
// operator runs deliberately before a one-way decision.

open ReventlessSeed

module Ddb = AwsSdk.DynamoDb
module Rgt = AwsSdk.ResourceGroupsTaggingApi
module S3 = AwsSdk.S3

// The tag the mint side writes and the claim component removes, restated rather
// than imported: the seed packages deliberately depend on no framework package —
// they drive a platform through its public API — so `Upload_PendingTag.key` is
// out of reach here.
//
// That makes this a duplicated constant, and the honest thing is to say what
// happens if it drifts rather than to claim it cannot. Reading the wrong key
// would report every object as untagged: a clean bill of health for a store this
// tool had not actually inspected. `print` therefore calls out the shape that
// drift produces — objects present, none of them tagged — instead of leaving it
// as a silent pass. Changing this string means changing `Upload_PendingTag.key`
// in reventless-aws, and vice versa.
let pendingTagKey = "reventless:pending"

// ── Collecting refs from the event log ───────────────────────────────────────

/** Every string under `/{prefix}/` anywhere in a committed event's payload.

    Recursive because an event's payload is whatever its schema says: a ref can
    sit at the top level, inside an array, or nested in a record. Depth costs
    nothing here and missing a ref costs an object. */
let rec collectRefs = (~prefix: string, json: JSON.t, into: Set.t<string>): unit =>
  switch json {
  | String(s) =>
    if s->String.startsWith(`/${prefix}/`) {
      into->Set.add(s)
    }
  | Array(items) => items->Array.forEach(item => collectRefs(~prefix, item, into))
  | Object(fields) => fields->Dict.valuesToArray->Array.forEach(v => collectRefs(~prefix, v, into))
  | _ => ()
  }

/** Scan one table for committed events and collect the refs they carry.

    Both the aggregate and the DCB event log store a row as
    `{event: "<Type>", data: {…}}`, so a row without an `event` attribute is not
    an event — a snapshot, a DCB fence row, or a read-model row in a table that
    is not an event log at all. That single check is what lets this scan every
    discovered table without having to know which ones are event logs. */
let refsInTable = async (~table: string, ~prefix: string, into: Set.t<string>): int => {
  let rec loop = async (start: option<dict<JSON.t>>, rows: int): int => {
    let out = await Ddb.DocumentClient.ScanCommand.send(
      Ddb.DocumentClient.ScanCommand.make({tableName: table, exclusiveStartKey: ?start}),
    )
    let items = out.items->Option.getOr([])
    items->Array.forEach(item =>
      switch item->JSON.Decode.object {
      | Some(row) =>
        switch (row->Dict.get("event"), row->Dict.get("data")) {
        | (Some(JSON.String(_)), Some(data)) => collectRefs(~prefix, data, into)
        | _ => ()
        }
      | None => ()
      }
    )
    let rows = rows + items->Array.length
    switch out.lastEvaluatedKey {
    | Some(k) => await loop(Some(k), rows)
    | None => rows
    }
  }
  await loop(None, 0)
}

// ── Collecting objects from the store ────────────────────────────────────────

/** One object in the store, and whether it is still provisional. */
type object = {
  key: string,
  /** The ref an event would carry for this object — the key with a leading `/`,
      which is exactly what the presign service minted. */
  ref: string,
  pending: bool,
}

let listObjects = async (~bucket: string, ~prefix: string): array<object> => {
  let keys = []
  let rec loop = async (keyMarker, versionMarker): unit => {
    let out = await S3.ListObjectVersionsCommand.send(
      S3.ListObjectVersionsCommand.make({
        bucket,
        prefix: `${prefix}/`,
        keyMarker: ?keyMarker,
        versionIdMarker: ?versionMarker,
      }),
    )
    // Current objects only. Store buckets are created with versioning off, so
    // in practice every version is the latest one; filtering keeps this honest
    // if a deployment ever turns versioning on.
    out.versions
    ->Option.getOr([])
    ->Array.forEach(v =>
      if v.isLatest {
        keys->Array.push(v.key)
      }
    )
    switch (out.isTruncated, out.nextKeyMarker) {
    | (Some(true), Some(_)) => await loop(out.nextKeyMarker, out.nextVersionIdMarker)
    | _ => ()
    }
  }
  await loop(None, None)

  // One tagging read per object. Sequential on purpose — this competes with a
  // live claim component for the same objects' tagging reads, and an operator
  // report has no deadline worth throttling production for.
  let objects = []
  await keys->Array.reduce(Promise.resolve(), (acc, key) =>
    acc->Promise.then(async _ => {
      let tagging = await S3.GetObjectTaggingCommand.send(
        S3.GetObjectTaggingCommand.make({bucket, key}),
      )
      let pending =
        tagging.tagSet->Option.getOr([])->Array.some(t => t.key == pendingTagKey)
      objects->Array.push({key, ref: `/${key}`, pending})
    })
  )
  objects
}

// ── The report ───────────────────────────────────────────────────────────────

/** The four populations, which are the whole point. Only one of them is a
    problem, and it is the one the lifecycle rule would delete. */
type report = {
  store: string,
  bucket: string,
  prefix: string,
  eventRows: int,
  /** Referenced by a committed event and STILL TAGGED PENDING. Enabling expiry
      would delete these. Must be empty before a store turns the rule on. */
  referencedButPending: array<object>,
  /** Tagged pending and referenced by nothing — what the rule is for. */
  unreferencedPending: array<object>,
  /** Referenced by nothing and carrying no tag: minted before the claim
      component existed, so outside the rule entirely and never collected. */
  unreferencedUntagged: array<object>,
  /** An event references it and the object is not there. Not this mechanism's
      doing — expiry only ever removes untagged-by-nobody objects — but a broken
      image is worth surfacing while everything is being counted anyway. */
  danglingRefs: array<string>,
}

let reconcileStore = async (
  ~store: string,
  ~bucket: string,
  ~prefix: string,
  ~tables: array<string>,
): report => {
  let refs = Set.make()
  let eventRows = ref(0)
  await tables->Array.reduce(Promise.resolve(), (acc, table) =>
    acc->Promise.then(async _ => {
      let rows = await refsInTable(~table, ~prefix, refs)
      eventRows := eventRows.contents + rows
    })
  )

  let objects = await listObjects(~bucket, ~prefix)
  let present = Set.make()
  objects->Array.forEach(o => present->Set.add(o.ref))

  {
    store,
    bucket,
    prefix,
    eventRows: eventRows.contents,
    referencedButPending: objects->Array.filter(o => o.pending && refs->Set.has(o.ref)),
    unreferencedPending: objects->Array.filter(o => o.pending && !(refs->Set.has(o.ref))),
    unreferencedUntagged: objects->Array.filter(o => !o.pending && !(refs->Set.has(o.ref))),
    danglingRefs: refs->Set.toArray->Array.filter(r => !(present->Set.has(r))),
  }
}

let sample = (objects: array<object>, ~limit: int=10): array<object> =>
  objects->Array.slice(~start=0, ~end=limit)

/** Print one store's report. Returns `true` when the store is safe to enable
    expiry on — that is, when nothing referenced is still tagged. */
let print = (r: report): bool => {
  Console.log("")
  Console.log(`  ${r.store}   ${r.bucket}/${r.prefix}/`)
  Console.log(`    event rows scanned: ${r.eventRows->Int.toString}`)
  let line = (label, n) => Console.log(`      ${n->Int.toString->String.padStart(8, " ")}  ${label}`)
  line("referenced, still tagged pending  ← must be 0", r.referencedButPending->Array.length)
  line("unreferenced, tagged pending      ← what expiry would delete", r.unreferencedPending->Array.length)
  line("unreferenced, untagged            ← outside the rule", r.unreferencedUntagged->Array.length)
  line("referenced but missing            ← dangling refs", r.danglingRefs->Array.length)

  // Every object untagged reads as "the claimer has caught up with everything",
  // and that is usually what it is. But it is also exactly what a drifted tag key
  // looks like, and the two are indistinguishable from the counts alone — so say
  // so rather than let a store pass on evidence that might mean nothing.
  let objectCount =
    r.referencedButPending->Array.length +
    r.unreferencedPending->Array.length +
    r.unreferencedUntagged->Array.length
  if objectCount > 0 && r.referencedButPending->Array.length == 0 && r.unreferencedPending->Array.length == 0 {
    Console.log("")
    Console.log(
      `    Note: none of the ${objectCount->Int.toString} objects carry "${pendingTagKey}". That is ` ++
      "what a fully-claimed store looks like — and also what it looks like if the mint side " ++
      "never wrote the tag (a store whose objects all predate it) or if this tool's tag key has " ++
      "drifted from the deploy's.",
    )
  }

  if r.referencedButPending->Array.length > 0 {
    Console.log("")
    Console.log("    Referenced objects that are still tagged pending:")
    sample(r.referencedButPending)->Array.forEach(o => Console.log(`      ${o.ref}`))
    if r.referencedButPending->Array.length > 10 {
      Console.log(`      … and ${(r.referencedButPending->Array.length - 10)->Int.toString} more`)
    }
    Console.log("")
    Console.log(
      "    Do NOT enable this store's expiry rule. Either the claim component is behind or " ++
      "stopped (check its IteratorAge alarm), or a field holding these refs is missing its " ++
      "`@storageRef` annotation — in which case the claimer never sees it and never will.",
    )
  }
  r.referencedButPending->Array.length == 0
}

/**
 * Reconcile every declared object store of a deployed stack.
 *
 * Reads the platform project's `objectStores` output for the store list, and
 * discovers each plugin project's DynamoDB tables by the framework's
 * `reventless:platform` + `reventless:environment` tags — the same scoping the
 * reset uses, for the same reason: a stack name alone is shared across projects.
 *
 * `targets` are the deployment's Pulumi projects, exactly as `Reset.run` takes
 * them. Exits non-zero when any store has a referenced object still tagged
 * pending, so a scheduled run of this is a usable check and not just a page of
 * numbers.
 */
let run = (~stack=?, ~backend=?, ~targets: array<ReventlessSeedAws_Reset.target>, ()): unit => {
  let go = async () => {
    try {
      if targets->Array.length == 0 {
        throw(Seed.Failed("no targets were declared — nothing to reconcile."))
      }
      let backend = switch Seed.Prompt.envValue("SEED_PULUMI_BACKEND") {
      | Some(url) => Some(url)
      | None => backend
      }
      let platformTarget = switch targets->Array.find(t => t.group == Platform) {
      | Some(t) => t
      | None =>
        throw(
          Seed.Failed(
            "no `platform` target is declared — declared object stores live in the platform " ++
            "project's stack output and cannot be resolved without it.",
          ),
        )
      }
      let stack = await ReventlessSeedAws.resolveStack(
        ~projectDir=platformTarget.projectDir,
        ~backend,
        ~stack,
      )

      let output = ReventlessSeedAws.stackOutputs(
        ~projectDir=platformTarget.projectDir,
        ~backend,
        stack,
      )
      let stores = switch ReventlessSeedAws_Reset.parseObjectStores(
        output->ReventlessSeedAws_Reset.field("objectStores"),
      ) {
      | Ok(stores) => stores
      | Error(message) => throw(Seed.Failed(message))
      }
      if stores->Array.length == 0 {
        Seed.Runner.heading(`Reconcile: stack "${stack}" declares no object stores.`)
      } else {
        let region = switch Seed.Prompt.envValue("AWS_REGION") {
        | Some(r) if r != "" => r
        | _ =>
          throw(Seed.Failed("could not resolve the AWS region — set AWS_REGION."))
        }
        Seed.Runner.heading(`Reconcile: stack "${stack}" in ${region}`)

        // A store's objects are referenced by the events of the plugin that
        // declared it — but a qualified `@storageRef("Other.store")` means
        // another plugin's events can carry them too, so every target's tables
        // are scanned for every store rather than only the owner's.
        let tables = []
        await targets->Array.reduce(Promise.resolve(), (acc, target) =>
          acc->Promise.then(async _ => {
            let platform = ReventlessSeedAws_Reset.projectName(~projectDir=target.projectDir)
            let found = await ReventlessSeedAws_Reset.discover(~region, ~stack, ~platform)
            found.tables->Array.forEach(t => tables->Array.push(t))
          })
        )

        let allClear = ref(true)
        await stores->Array.reduce(Promise.resolve(), (acc, s) =>
          acc->Promise.then(async _ => {
            let report = await reconcileStore(
              ~store=s.qualified,
              ~bucket=s.bucketName,
              ~prefix=s.keyPrefix,
              ~tables,
            )
            if !print(report) {
              allClear := false
            }
          })
        )
        Console.log("")
        if allClear.contents {
          Console.log(
            "Every referenced object has been claimed. Enabling a store's expiry rule " ++
            "(`pendingUploadExpiryDays: \"<plugin>.<store>=<days>\"`) would delete only " ++
            "objects nothing references.",
          )
        } else {
          throw(
            Seed.Failed(
              "at least one referenced object is still tagged pending — see above. No store's " ++
              "expiry rule should be enabled while this is true.",
            ),
          )
        }
      }
      NodeProcess.exit(0)
    } catch {
    | Seed.Failed(message) =>
      Console.error("")
      Console.error(`Reconcile failed — ${message}`)
      NodeProcess.exit(1)
    | exn =>
      Console.error("")
      Console.error("Reconcile failed with an unexpected error:")
      Console.error(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"))
      NodeProcess.exit(1)
    }
  }
  go()->ignore
}
