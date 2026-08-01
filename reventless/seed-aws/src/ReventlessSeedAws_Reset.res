// AWS "reset" for the seed harness: truncate a deployed stack's durable stores
// — every DynamoDB table (EventLog, DcbEventLog, QueryDb) and every S3 bucket
// (tasks, served images) the framework created for the stack — leaving the
// infrastructure in place so the stack reads empty and is re-seedable. It is the
// exact inverse of seeding: `Seed.Runner.assertStoreEmpty` refuses to seed a
// non-empty store; this makes a non-empty store empty again.
//
// A wipe is irreversible, so every step is fail-closed and production must be
// unreachable at several at once (the separate-AWS-account guarantee is the one
// deferred layer — see docs/plans/seed-reset-and-fresh-store-guard.md):
//
//   1. name allowlist    — the stack name must match ^(alpha|dev|pr-.+)$
//   2. wipeable flag      — the target's own `Pulumi.<stack>.yaml` must declare
//                           `reventless:wipeable: true` (read via `pulumi config`)
//   3. tag-scoped discovery — targets are found ONLY through the framework's
//                           `reventless:platform=<project>` + `environment=<stack>`
//                           tags (Resource Groups Tagging API). Scoping on BOTH
//                           matters: `environment` is the stack NAME alone, so two
//                           projects sharing a stack name (e.g. `alpha`) in one
//                           account collide on it; `platform` (the Pulumi project)
//                           keeps a wipe inside the one project. No name globbing.
//   4. per-resource tag re-check — every discovered resource is re-verified to
//                           carry both tags before a single delete is issued
//   5. dry-run default + typed confirm — lists what it would empty and stops.
//                           Interactively, re-typing the exact stack name confirms
//                           a real wipe (no env var). Without a TTY (CI),
//                           REVENTLESS_WIPE_CONFIRM=<stack> is the equivalent.
//
// Gates 1 and 2 are AND-ed: a stray `wipeable: true` on an unlisted name is
// still refused, and a listed name without the flag is still refused. Production
// stacks satisfy neither.
//
// A deployment is usually several Pulumi projects sharing a stack name — the
// platform project plus one per domain plugin, each its own `reventless:platform`.
// The caller passes those projects as `targets`; the operator picks a scope
// (`domain` = all plugins, a single plugin, `platform`, or `everything`), and
// gate 2 + discovery run per selected project. Wiping domain data alone leaves
// the platform's plugin registry intact, so the store stays re-seedable.
//
// Stack resolution reuses `ReventlessSeedAws` (same `pulumi` subprocess, same
// backend pinning). AWS credentials come from the ambient chain (env / profile /
// SSO); only the region is resolved explicitly and pinned on the environment, so
// every SDK client targets the same account/region the tags were read from.

open ReventlessSeed

module Ddb = AwsSdk.DynamoDb
module Rgt = AwsSdk.ResourceGroupsTaggingApi
module S3 = AwsSdk.S3



// The Pulumi project name, which the framework stamps as `reventless:platform` on
// every resource (`Plugin.res`: `platformName = getProjectName()`). Discovery
// MUST scope on this as well as the stack: `reventless:environment` carries only
// the stack *name*, so two different Pulumi projects deployed with the same stack
// name (e.g. `alpha`) in one account/region share that tag. Filtering by platform
// too keeps a wipe inside the one project the operator is standing in. Read from
// the target project's Pulumi.yaml — the same dir the pulumi subprocess uses.
let projectName = (~projectDir: string): string => {
  let path = `${projectDir}/Pulumi.yaml`
  let raw = try NodeFs.readFileSync(path) catch {
  | _ => throw(Seed.Failed(`could not read ${path} to scope the wipe to this Pulumi project.`))
  }
  switch raw
  ->String.split("\n")
  ->Array.find(line => line->String.trim->String.startsWith("name:")) {
  | Some(line) =>
    let trimmed = line->String.trim
    trimmed
    ->String.slice(~start=String.length("name:"), ~end=String.length(trimmed))
    ->String.trim
    ->String.replaceRegExp(%re("/^[\"']|[\"']$/g"), "")
  | None => throw(Seed.Failed(`could not find a \`name:\` field in ${path}.`))
  }
}

// A read of a JSON object field — items come back from the document client as
// already-unmarshalled JSON values, so a delete key is just the key attributes
// picked back out.
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

let chunk = (arr: array<'a>, size: int): array<array<'a>> => {
  let out = []
  let i = ref(0)
  while i.contents < arr->Array.length {
    out->Array.push(arr->Array.slice(~start=i.contents, ~end=i.contents + size))
    i := i.contents + size
  }
  out
}

// ── Gates ───────────────────────────────────────────────────────────────────

// Fail-closed name allowlist. A denylist ("everything except prod") fails open
// the day a new prod-like stack is added and forgotten; this fails closed.
let nameAllowlist = %re("/^(alpha|dev|pr-.+)$/")

// The stack's fully-resolved Pulumi config, read once. Reading it whole (rather
// than `pulumi config get <key>`, which exits non-zero for BOTH a missing key
// and a missing/unreachable stack) lets a refusal say *which* it was — an
// unreadable config is a pulumi/backend problem; an absent flag is a missing
// opt-in. `pulumi config --json` maps each key to `{value, secret}`.
let readStackConfig = (~projectDir, ~backend, ~stack): result<dict<JSON.t>, string> =>
  switch (
    try Some(ReventlessSeedAws.pulumi(~projectDir, ~backend, ["config", "--json", "--stack", stack])) catch {
    | _ => None
    }
  ) {
  | None =>
    Error(
      `could not read the Pulumi config for stack "${stack}" — is pulumi logged in to the right backend, and is the stack deployed?`,
    )
  | Some(raw) =>
    switch (
      try Some(JSON.parseOrThrow(raw)) catch {
      | _ => None
      }
    ) {
    | Some(Object(obj)) => Ok(obj)
    | _ => Error(`could not parse \`pulumi config --json\` output for stack "${stack}".`)
    }
  }

let configValue = (cfg: dict<JSON.t>, key: string): option<string> =>
  cfg->Dict.get(key)->Option.flatMap(v => v->field("value"))->Option.flatMap(asString)

// ── Discovery ─────────────────────────────────────────────────────────────────

type resource =
  | Table(string)
  | Bucket(string)
  | Other

// arn:aws:dynamodb:<region>:<acct>:table/<name>  |  arn:aws:s3:::<bucket>
let classify = (arn: string): resource =>
  if arn->String.startsWith("arn:aws:dynamodb:") {
    switch arn->String.split(":table/") {
    | [_, name] => Table(name)
    | _ => Other
    }
  } else if arn->String.startsWith("arn:aws:s3:::") {
    Bucket(arn->String.slice(~start=String.length("arn:aws:s3:::"), ~end=String.length(arn)))
  } else {
    Other
  }

let tagValue = (tags: array<Rgt.GetResourcesCommand.tag>, key: string): option<string> =>
  tags->Array.findMap(t => t.key == key ? Some(t.value) : None)

// Discovery is scoped by BOTH tags (platform AND environment) — the Tagging API
// ANDs multiple TagFilters — so it only ever sees the target project's own stack,
// never a same-named stack from another project. Each returned resource is then
// re-checked to carry both tags (a mismatch aborts the whole run rather than
// being skipped) as a second, per-resource guard.
let discover = async (~region, ~stack, ~platform): (array<string>, array<string>) => {
  let client = Rgt.client(~region, ())
  let tables = []
  let buckets = []
  let rec loop = async (token: option<string>): unit => {
    let out = await Rgt.GetResourcesCommand.send(
      client,
      Rgt.GetResourcesCommand.make({
        tagFilters: [
          {key: "reventless:platform", values: [platform]},
          {key: "reventless:environment", values: [stack]},
        ],
        resourceTypeFilters: ["dynamodb:table", "s3"],
        resourcesPerPage: 100,
        paginationToken: ?token,
      }),
    )
    out.resourceTagMappingList
    ->Option.getOr([])
    ->Array.forEach(m => {
      let tags = m.tags->Option.getOr([])
      let assertTag = (key, expected) =>
        switch tagValue(tags, key) {
        | Some(v) if v == expected => ()
        | other =>
          throw(
            Seed.Failed(
              `refusing: discovered resource ${m.resourceARN} carries ${key}=${other->Option.getOr(
                  "<none>",
                )}, not "${expected}".`,
            ),
          )
        }
      assertTag("reventless:platform", platform)
      assertTag("reventless:environment", stack)
      switch classify(m.resourceARN) {
      | Table(name) => tables->Array.push(name)
      | Bucket(name) => buckets->Array.push(name)
      | Other => ()
      }
    })
    switch out.paginationToken {
    | Some(t) if t != "" => await loop(Some(t))
    | _ => ()
    }
  }
  await loop(None)
  (tables, buckets)
}

// ── Declared object stores ────────────────────────────────────────────────────
//
// A store declared by a `@storageRef` field is provisioned by the PLATFORM
// deploy — the serving CDN and the presign services live there, and a
// shared-layout bucket holds several plugins' stores, so no plugin stack can own
// it. Its bucket therefore carries the platform project's `reventless:platform`
// tag, which makes it invisible to a domain-scoped tag discovery and, worse,
// wholesale-emptiable by a platform-scoped one.
//
// Tag discovery cannot fix that: the tag says which project *built* the bucket,
// and the answer needed here is which plugin's data is *in* it — at prefix
// granularity, since one bucket holds several plugins' stores. The platform
// already publishes exactly that mapping as its `objectStores` stack output, so
// the reset reads ownership from the declaration rather than inferring it.

/** One provisioned store: which plugin owns it, and where its objects live. */
type objectStore = {
  qualified: string,
  plugin: string,
  store: string,
  bucketName: string,
  keyPrefix: string,
}

// A store's key is `{plugin}.{store}`, split at the FIRST dot: a registered
// plugin name cannot contain one, a store name could in principle.
let splitQualified = (key: string): option<(string, string)> =>
  key
  ->String.indexOfOpt(".")
  ->Option.map(i => (
    key->String.slice(~start=0, ~end=i),
    key->String.slice(~start=i + 1, ~end=key->String.length),
  ))

/** Parse the platform stack's `objectStores` output. Absent is normal — a
    platform may declare no stores — so only a malformed entry is an error, and
    it is an error rather than a skip because a store the reset cannot read is a
    store it would silently leave behind. */
let parseObjectStores = (json: option<JSON.t>): result<array<objectStore>, string> =>
  switch json {
  | None => Ok([])
  | Some(Object(entries)) =>
    entries
    ->Dict.toArray
    ->Array.reduce(Ok([]), (acc, (qualified, entry)) =>
      switch acc {
      | Error(_) as failed => failed
      | Ok(stores) =>
        switch (
          splitQualified(qualified),
          entry->field("bucketName")->Option.flatMap(asString),
          entry->field("keyPrefix")->Option.flatMap(asString),
        ) {
        | (Some((plugin, store)), Some(bucketName), Some(keyPrefix)) =>
          Ok(Array.concat(stores, [{qualified, plugin, store, bucketName, keyPrefix}]))
        | _ =>
          Error(
            `the platform stack's \`objectStores\` output has a malformed entry for "${qualified}" — ` ++
            `expected a {plugin}.{store} key carrying bucketName and keyPrefix.`,
          )
        }
      }
    )
  | Some(_) => Error("the platform stack's `objectStores` output is not an object.")
  }

/** Refuse any store set a prefix-scoped wipe cannot separate.

    Equality is the cross-plugin collision: two plugins declaring one store name
    land on one prefix inside a shared bucket, and nothing distinguishes their
    objects. Containment is the same problem one level up — the delete prefix is
    `{keyPrefix}/`, so a store rooted at `a` encloses one rooted at `a/b`.
    Comparing containment rather than equality is what keeps this correct once a
    prefix carries path structure.

    Fail-closed, and before anything is counted: this is the tool that destroys
    data, so it refuses rather than skipping, and it does not assume an upstream
    deploy-time check ran. */
let validateStores = (stores: array<objectStore>): result<unit, string> =>
  switch stores->Array.find(s => s.keyPrefix == "" || s.store->String.includes("/")) {
  | Some(s) =>
    Error(
      `store "${s.qualified}" has an unusable key prefix ("${s.keyPrefix}") — ` ++
      `a store name may not be empty or contain "/".`,
    )
  | None =>
    switch stores->Array.findMap(a =>
      stores->Array.findMap(b =>
        if a.qualified == b.qualified || a.bucketName != b.bucketName {
          None
        } else if a.keyPrefix == b.keyPrefix {
          Some(
            `stores "${a.qualified}" and "${b.qualified}" both live at ` ++
            `${a.bucketName}/${a.keyPrefix}/ — a prefix-scoped wipe cannot tell their objects ` ++
            `apart. Rename one store, or qualify the \`@storageRef\` annotation if they were ` ++
            `meant to be one shared store.`,
          )
        } else if b.keyPrefix->String.startsWith(a.keyPrefix ++ "/") {
          Some(
            `store "${a.qualified}" (${a.bucketName}/${a.keyPrefix}/) encloses "${b.qualified}" ` ++
            `(${b.keyPrefix}/) — wiping the first would delete the second's objects. Rename one.`,
          )
        } else {
          None
        }
      )
    ) {
    | Some(message) => Error(message)
    | None => Ok()
    }
  }

// ── Counting (dry-run) ─────────────────────────────────────────────────────────

let countTable = async (table: string): int => {
  let rec loop = async (start: option<dict<JSON.t>>, acc: int): int => {
    let out = await Ddb.DocumentClient.ScanCommand.send(
      Ddb.DocumentClient.ScanCommand.make({
        tableName: table,
        select: #COUNT,
        exclusiveStartKey: ?start,
      }),
    )
    let acc = acc + out.count->Option.getOr(0)
    switch out.lastEvaluatedKey {
    | Some(k) => await loop(Some(k), acc)
    | None => acc
    }
  }
  await loop(None, 0)
}

// `~prefix` narrows the count to one declared store inside a shared bucket;
// omitted, it counts the whole bucket.
let countBucket = async (bucket: string, ~prefix: option<string>=?): int => {
  let rec loop = async (keyMarker, versionMarker, acc): int => {
    let out = await S3.ListObjectVersionsCommand.send(
      S3.ListObjectVersionsCommand.make({
        bucket,
        prefix: ?prefix,
        keyMarker: ?keyMarker,
        versionIdMarker: ?versionMarker,
      }),
    )
    let n =
      out.versions->Option.getOr([])->Array.length +
        out.deleteMarkers->Option.getOr([])->Array.length
    if out.isTruncated->Option.getOr(false) {
      await loop(out.nextKeyMarker, out.nextVersionIdMarker, acc + n)
    } else {
      acc + n
    }
  }
  await loop(None, None, 0)
}

// ── Wiping ──────────────────────────────────────────────────────────────────

// BatchWrite takes ≤ 25 requests and may return some UnprocessedItems under
// throttling; resend those. Capped so a persistently-failing table surfaces as
// an error rather than looping forever.
let rec sendBatch = async (
  table: string,
  requests: array<Ddb.DocumentClient.BatchWriteCommand.writeRequest>,
  ~attempt: int,
): unit =>
  if requests->Array.length > 0 {
    if attempt > 8 {
      throw(Seed.Failed(`table ${table}: ${(requests->Array.length)->Int.toString} item(s) still unprocessed after 8 retries.`))
    }
    let out = await Ddb.DocumentClient.BatchWriteCommand.send(
      Ddb.DocumentClient.BatchWriteCommand.make({
        requestItems: Dict.fromArray([(table, requests)]),
      }),
    )
    let unprocessed =
      out.unprocessedItems->Option.flatMap(d => d->Dict.get(table))->Option.getOr([])
    if unprocessed->Array.length > 0 {
      await sendBatch(table, unprocessed, ~attempt=attempt + 1)
    }
  }

let truncateTable = async (table: string): unit => {
  let desc = await Ddb.DynamoDb.DescribeTableCommand.send(
    Ddb.DynamoDb.DescribeTableCommand.make({tableName: table}),
  )
  let keyAttrs =
    desc.table->Option.flatMap(t => t.keySchema)->Option.getOr([])->Array.map(k => k.attributeName)
  if keyAttrs->Array.length == 0 {
    throw(Seed.Failed(`could not read a key schema for table ${table}.`))
  }
  // Project only the key attributes (aliased to dodge reserved words) so the
  // scan carries just what a delete needs.
  let names = keyAttrs->Array.mapWithIndex((name, i) => (`#k${i->Int.toString}`, name))
  let projection = names->Array.map(((alias, _)) => alias)->Array.join(", ")
  let rec loop = async (start: option<dict<JSON.t>>): unit => {
    let out = await Ddb.DocumentClient.ScanCommand.send(
      Ddb.DocumentClient.ScanCommand.make({
        tableName: table,
        exclusiveStartKey: ?start,
        projectionExpression: projection,
        expressionAttributeNames: names->Dict.fromArray,
      }),
    )
    let requests =
      out.items
      ->Option.getOr([])
      ->Array.map(item => {
        let key =
          keyAttrs->Array.filterMap(attr => item->field(attr)->Option.map(v => (attr, v)))->Dict.fromArray
        ({deleteRequest: {key: key}}: Ddb.DocumentClient.BatchWriteCommand.writeRequest)
      })
    let batches = chunk(requests, Ddb.DocumentClient.BatchWriteCommand.maxBatchSize)
    for i in 0 to batches->Array.length - 1 {
      switch batches->Array.get(i) {
      | Some(b) => await sendBatch(table, b, ~attempt=1)
      | None => ()
      }
    }
    switch out.lastEvaluatedKey {
    | Some(k) => await loop(Some(k))
    | None => ()
    }
  }
  await loop(None)
}

// One ListObjectVersions page returns ≤ 1000 entries (versions + delete
// markers), and DeleteObjects takes ≤ 1000, so one list page maps to one delete.
let emptyBucket = async (bucket: string, ~prefix: option<string>=?): unit => {
  let rec loop = async (keyMarker, versionMarker): unit => {
    let out = await S3.ListObjectVersionsCommand.send(
      S3.ListObjectVersionsCommand.make({
        bucket,
        prefix: ?prefix,
        keyMarker: ?keyMarker,
        versionIdMarker: ?versionMarker,
      }),
    )
    let ids =
      Array.concat(out.versions->Option.getOr([]), out.deleteMarkers->Option.getOr([]))->Array.map(v => (
        {key: v.key, versionId: v.versionId}: S3.DeleteObjectsCommand.objectIdentifier
      ))
    if ids->Array.length > 0 {
      let res = await S3.DeleteObjectsCommand.send(
        S3.DeleteObjectsCommand.make({
          bucket,
          delete: {objects: ids, quiet: true},
        }),
      )
      switch res.errors {
      | Some(errs) if errs->Array.length > 0 =>
        throw(
          Seed.Failed(
            `failed to delete ${(errs->Array.length)->Int.toString} object(s) from ${bucket}: ${errs
              ->Array.get(0)
              ->Option.flatMap(e => e.message)
              ->Option.getOr("unknown")}`,
          ),
        )
      | _ => ()
      }
    }
    if out.isTruncated->Option.getOr(false) {
      await loop(out.nextKeyMarker, out.nextVersionIdMarker)
    }
  }
  await loop(None, None)
}

// ── Targets & scope ───────────────────────────────────────────────────────────

// A deployment is several Pulumi projects sharing a stack name — the platform
// project plus one per domain plugin — each a separate `reventless:platform`. A
// target names one such project by the directory its `Pulumi.<stack>.yaml` lives
// in (relative to the seed cwd), plus a menu label and whether it holds domain
// data or platform bookkeeping. The caller declares them; the reset never guesses
// the topology.
type group =
  | Domain
  | Platform

type target = {
  projectDir: string,
  label: string,
  group: group,
  // The name this project's plugin REGISTERS, when it differs from the
  // operator-facing `label` (`Catalog` against `catalog`). It is what the
  // platform's `objectStores` keys are qualified by, so it is how a declared
  // store is attributed to a target. Declared rather than case-folded from the
  // label: the caller states the topology, the reset never guesses it.
  plugin?: string,
}

let pluginOf = (t: target): string => t.plugin->Option.getOr(t.label)

// A target resolved to its discovered, counted stores, ready to report and wipe.
type resolved = {
  target: target,
  platform: string,
  tables: array<string>,
  tableCounts: array<int>,
  bucketCounts: array<(string, int)>,
  storeCounts: array<(objectStore, int)>,
}

// Picks which targets to wipe. `domain` (every domain plugin) leads and is the
// default; each single domain plugin follows so one plugin's data can be wiped
// alone; then `platform`; then `everything`. `SEED_RESET_SCOPE` (domain |
// platform | everything | a plugin label) selects non-interactively.
let chooseScope = async (~targets: array<target>): array<target> => {
  let domain = targets->Array.filter(t => t.group == Domain)
  let platform = targets->Array.filter(t => t.group == Platform)
  let labelsOf = ts => ts->Array.map(t => t.label)->Array.join(", ")
  switch Seed.Prompt.envValue("SEED_RESET_SCOPE")->Option.map(String.toLowerCase) {
  | Some("domain") => domain
  | Some("platform") => platform
  | Some("all") | Some("everything") | Some("both") => targets
  | Some(other) =>
    switch targets->Array.find(t => t.label->String.toLowerCase == other) {
    | Some(t) => [t]
    | None =>
      throw(
        Seed.Failed(
          `SEED_RESET_SCOPE="${other}" is not a scope — use domain, platform, everything, or a plugin label (${labelsOf(
              domain,
            )}).`,
        ),
      )
    }
  | None =>
    let options = []
    if domain->Array.length > 0 {
      options->Array.push((`domain — ${labelsOf(domain)}`, domain))
      // Single-plugin entries only when there is more than one, else they just
      // duplicate the `domain` entry.
      if domain->Array.length > 1 {
        domain->Array.forEach(t => options->Array.push((t.label, [t])))
      }
    }
    if platform->Array.length > 0 {
      options->Array.push((`platform — ${labelsOf(platform)}`, platform))
    }
    if domain->Array.length > 0 && platform->Array.length > 0 {
      options->Array.push((`everything — ${labelsOf(targets)}`, targets))
    }
    await Seed.Prompt.select(~title="Reset scope:", ~options)
  }
}

// ── Orchestration ─────────────────────────────────────────────────────────────

// Gate 2 per target: its own `Pulumi.<stack>.yaml` must declare wipeable, and
// must resolve a region. Reasons are distinct (config unreadable vs opt-in
// missing vs region missing), each saying what to fix. Returns the target's
// region so the caller can insist every selected target shares one.
let gateTarget = (~target: target, ~backend, ~stack): string => {
  let cfg = switch readStackConfig(~projectDir=target.projectDir, ~backend, ~stack) {
  | Ok(c) => c
  | Error(message) => throw(Seed.Failed(message))
  }
  switch configValue(cfg, "reventless:wipeable")->Option.map(v => v->String.trim->String.toLowerCase) {
  | Some("true") => ()
  | _ =>
    throw(
      Seed.Failed(
        `${target.label}: stack "${stack}" does not declare \`reventless:wipeable: "true"\` in its Pulumi.${stack}.yaml — refusing. Add that line only on disposable dev stacks (see the alpha example configs).`,
      ),
    )
  }
  switch Seed.Prompt.envValue("AWS_REGION") {
  | Some(r) if r != "" => r
  | _ =>
    switch configValue(cfg, "aws:region") {
    | Some(r) if r != "" => r
    | _ =>
      throw(
        Seed.Failed(
          `${target.label}: could not resolve the AWS region — set AWS_REGION or \`aws:region\` in the stack config.`,
        ),
      )
    }
  }
}

let reportAll = (resolvedList: array<resolved>, ~stack, ~region): int => {
  Seed.Runner.heading(`Reset target: stack "${stack}" in ${region}`)
  let total = ref(0)
  resolvedList->Array.forEach(r => {
    Console.log("")
    Console.log(`  ${r.target.label}  (${r.platform})`)
    Console.log("    DynamoDB tables:")
    r.tables->Array.forEachWithIndex((t, i) => {
      let c = r.tableCounts->Array.get(i)->Option.getOr(0)
      total := total.contents + c
      Console.log(`      ${c->Int.toString->String.padStart(8, " ")}  ${t}`)
    })
    if r.tables->Array.length == 0 {
      Console.log("      (none)")
    }
    Console.log("    S3 buckets:")
    r.bucketCounts->Array.forEach(((b, c)) => {
      total := total.contents + c
      Console.log(`      ${c->Int.toString->String.padStart(8, " ")}  ${b}`)
    })
    if r.bucketCounts->Array.length == 0 {
      Console.log("      (none)")
    }
    // Declared stores get their own section rather than being folded in with the
    // plain buckets: the unit is a prefix inside a bucket that other plugins also
    // write to, and the operator needs to see which is which before confirming.
    if r.storeCounts->Array.length > 0 {
      Console.log("    Object stores:")
      r.storeCounts->Array.forEach(((s, c)) => {
        total := total.contents + c
        Console.log(
          `      ${c->Int.toString->String.padStart(8, " ")}  ${s.qualified}   ` ++
          `${s.bucketName}/${s.keyPrefix}/`,
        )
      })
    }
  })
  total.contents
}

/**
 * Reset a deployed stack across one or more of its Pulumi projects. Resolves the
 * shared stack name, refuses unless it is on the name allowlist, lets the
 * operator pick a scope (domain / a single plugin / platform / everything), then
 * for each chosen project: refuses unless it declares itself wipeable, discovers
 * its stores by `platform`+`environment` tag, and reports what it would empty.
 * Only on a matching `REVENTLESS_WIPE_CONFIRM` plus a re-typed stack name does it
 * truncate every table and empty every bucket, then verify empty.
 *
 * `targets` are the deployment's projects (the caller knows the topology);
 * `stack` and `backend` mirror `ReventlessSeedAws.connect`.
 */
let run = (~stack=?, ~backend=?, ~targets: array<target>, ()): unit => {
  let go = async () => {
    try {
      if targets->Array.length == 0 {
        throw(Seed.Failed("no targets were declared — nothing to reset."))
      }
      let backend = switch Seed.Prompt.envValue("SEED_PULUMI_BACKEND") {
      | Some(url) => Some(url)
      | None => backend
      }
      // Any target's dir lists the shared stack; prefer the platform project.
      let baseTarget =
        targets->Array.find(t => t.group == Platform)->Option.getOr(targets->Array.getUnsafe(0))
      let stack = await ReventlessSeedAws.resolveStack(
        ~projectDir=baseTarget.projectDir,
        ~backend,
        ~stack,
      )

      if !(nameAllowlist->RegExp.test(stack)) {
        throw(
          Seed.Failed(
            `stack "${stack}" is not on the wipe name-allowlist (alpha, dev, pr-*) — refusing.`,
          ),
        )
      }

      let selected = await chooseScope(~targets)

      // Declared object stores live in a bucket the PLATFORM project owns, so
      // resolving them reads the platform's stack output whichever scope was
      // picked. Reading is side-effect free; the gates below decide whether
      // anything may be deleted from it.
      let platformTarget = targets->Array.find(t => t.group == Platform)
      let allStores = switch platformTarget {
      | None =>
        // Not silent: a topology with no platform target is exactly the case
        // where declared stores would be missed, and missing them is the bug
        // this resolution exists to fix.
        Console.log("")
        Console.log(
          "Note: no `platform` target is declared, so declared object stores could not be " ++
          "resolved — any uploaded objects will be left in place.",
        )
        []
      | Some(pt) =>
        let output = ReventlessSeedAws.stackOutputs(~projectDir=pt.projectDir, ~backend, stack)
        switch parseObjectStores(output->field("objectStores")) {
        | Ok(stores) => stores
        | Error(message) => throw(Seed.Failed(message))
        }
      }
      switch validateStores(allStores) {
      | Ok() => ()
      | Error(message) => throw(Seed.Failed(`refusing: ${message}`))
      }

      // Every bucket that holds a declared store, selected or not. These are
      // excluded from the plain per-target bucket lists below so a store is
      // reachable ONLY through the plugin that declared it — otherwise the
      // platform scope would empty every plugin's objects wholesale.
      let storeBucketNames = allStores->Array.map(s => s.bucketName)
      let selectedStores =
        allStores->Array.filter(s => selected->Array.some(t => pluginOf(t) == s.plugin))

      // Gate every selected target and collect its region; all must agree, since
      // the DynamoDB/S3 clients read one region from the environment. When a
      // store is in scope, the platform's own stack must also declare itself
      // wipeable — the objects belong to a plugin, but the bucket is the
      // platform's, and both consents are needed to delete from it.
      let gated = switch (selectedStores->Array.length > 0, platformTarget) {
      | (true, Some(pt)) if !(selected->Array.some(t => t.projectDir == pt.projectDir)) =>
        Array.concat(selected, [pt])
      | _ => selected
      }
      let regions = gated->Array.map(t => gateTarget(~target=t, ~backend, ~stack))
      let region = regions->Array.getUnsafe(0)
      if regions->Array.some(r => r != region) {
        throw(
          Seed.Failed(
            `selected targets span more than one region (${regions->Array.join(
                ", ",
              )}) — reset them one region at a time.`,
          ),
        )
      }
      NodeProcess.env->Dict.set("AWS_REGION", region)

      // A store bucket arrives by stack output, not by tag discovery, so the
      // per-resource tag re-check has to be applied to it explicitly: confirm it
      // carries the platform project's own `platform`+`environment` tags before
      // anything is deleted from it. One extra tagging-API call, and only when a
      // store is actually in scope.
      if selectedStores->Array.length > 0 {
        switch platformTarget {
        | Some(pt) =>
          let platformProject = projectName(~projectDir=pt.projectDir)
          let (_, platformBuckets) = await discover(~region, ~stack, ~platform=platformProject)
          selectedStores->Array.forEach(s =>
            if !(platformBuckets->Array.includes(s.bucketName)) {
              throw(
                Seed.Failed(
                  `refusing: store "${s.qualified}" names bucket ${s.bucketName}, which does not ` ++
                  `carry reventless:platform=${platformProject} + reventless:environment=${stack}.`,
                ),
              )
            }
          )
        | None => ()
        }
      }

      // Discover + count each target, scoped to its own project via the platform
      // tag so a same-named stack from another project is never touched.
      let resolvedList = []
      for i in 0 to selected->Array.length - 1 {
        switch selected->Array.get(i) {
        | Some(target) =>
          let platform = projectName(~projectDir=target.projectDir)
          let (tables, buckets) = await discover(~region, ~stack, ~platform)
          let tables = tables->Array.toSorted(String.compare)
          let buckets =
            buckets
            ->Array.filter(b => !(storeBucketNames->Array.includes(b)))
            ->Array.toSorted(String.compare)
          let tableCounts = []
          for j in 0 to tables->Array.length - 1 {
            switch tables->Array.get(j) {
            | Some(t) => tableCounts->Array.push(await countTable(t))
            | None => ()
            }
          }
          let bucketCounts = []
          for j in 0 to buckets->Array.length - 1 {
            switch buckets->Array.get(j) {
            | Some(b) => bucketCounts->Array.push((b, await countBucket(b)))
            | None => ()
            }
          }
          let stores = selectedStores->Array.filter(s => s.plugin == pluginOf(target))
          let storeCounts = []
          for j in 0 to stores->Array.length - 1 {
            switch stores->Array.get(j) {
            | Some(s) =>
              storeCounts->Array.push((
                s,
                await countBucket(s.bucketName, ~prefix=`${s.keyPrefix}/`),
              ))
            | None => ()
            }
          }
          resolvedList->Array.push({
            target,
            platform,
            tables,
            tableCounts,
            bucketCounts,
            storeCounts,
          })
        | None => ()
        }
      }

      let total = reportAll(resolvedList, ~stack, ~region)
      if total == 0 {
        Seed.Prompt.close()
        Console.log("")
        Console.log(`Nothing to reset — the selected scope already reads empty in ${region}.`)
        NodeProcess.exit(0)
      }

      // Confirmation. Interactively, re-typing the exact stack name IS the
      // confirmation — the validation above (allowlist + wipeable + tag checks)
      // plus a deliberate keystroke is enough, so no env var is needed. Without a
      // TTY (CI/scripts) there is nothing to type into, so
      // REVENTLESS_WIPE_CONFIRM=<stack> is the equivalent opt-in. Dry-run is the
      // default either way.
      let interactive = NodeProcess.stdin->NodeProcess.isTTY->Option.getOr(false)
      let confirmed = if interactive {
        let typed = await Seed.Prompt.ask(
          `About to permanently empty ${total->Int.toString} item(s)/object(s) across the selected scope of "${stack}". ` ++
          `Type the stack name to confirm, or press Enter to keep this a dry run: `,
        )
        typed->String.trim == stack
      } else {
        Seed.Prompt.envValue("REVENTLESS_WIPE_CONFIRM") == Some(stack)
      }
      Seed.Prompt.close()
      if !confirmed {
        Console.log("")
        Console.log(
          interactive
            ? "Dry run — nothing was deleted."
            : `Dry run — nothing was deleted. Set REVENTLESS_WIPE_CONFIRM=${stack} to empty this scope non-interactively.`,
        )
        NodeProcess.exit(0)
      }

      for i in 0 to resolvedList->Array.length - 1 {
        switch resolvedList->Array.get(i) {
        | Some(r) =>
          Seed.Runner.heading(`Emptying ${r.target.label} …`)
          for j in 0 to r.tables->Array.length - 1 {
            switch r.tables->Array.get(j) {
            | Some(t) =>
              await truncateTable(t)
              Console.log(`  truncated ${t}`)
            | None => ()
            }
          }
          for j in 0 to r.bucketCounts->Array.length - 1 {
            switch r.bucketCounts->Array.get(j) {
            | Some((b, _)) =>
              await emptyBucket(b)
              Console.log(`  emptied ${b}`)
            | None => ()
            }
          }
          // Report the count with the store, not just in the run total: "how
          // many images went" is the question an operator is actually asking.
          for j in 0 to r.storeCounts->Array.length - 1 {
            switch r.storeCounts->Array.get(j) {
            | Some((s, count)) =>
              await emptyBucket(s.bucketName, ~prefix=`${s.keyPrefix}/`)
              Console.log(
                `  emptied ${s.qualified} — ${count->Int.toString} object(s) removed from ` ++
                `${s.bucketName}/${s.keyPrefix}/`,
              )
            | None => ()
            }
          }
        | None => ()
        }
      }

      // Prove empty — the inverse of the post-seed verify.
      let remaining = ref(0)
      for i in 0 to resolvedList->Array.length - 1 {
        switch resolvedList->Array.get(i) {
        | Some(r) =>
          for j in 0 to r.tables->Array.length - 1 {
            switch r.tables->Array.get(j) {
            | Some(t) => remaining := remaining.contents + (await countTable(t))
            | None => ()
            }
          }
          for j in 0 to r.bucketCounts->Array.length - 1 {
            switch r.bucketCounts->Array.get(j) {
            | Some((b, _)) => remaining := remaining.contents + (await countBucket(b))
            | None => ()
            }
          }
          // Per-store confirmation, so "every uploaded object is gone" is an
          // observed fact rather than an inference from a global total.
          for j in 0 to r.storeCounts->Array.length - 1 {
            switch r.storeCounts->Array.get(j) {
            | Some((s, _)) =>
              let left = await countBucket(s.bucketName, ~prefix=`${s.keyPrefix}/`)
              remaining := remaining.contents + left
              Console.log(
                `  verified empty: ${s.qualified} — ${left->Int.toString} object(s) remain under ` ++
                `${s.bucketName}/${s.keyPrefix}/`,
              )
            | None => ()
            }
          }
        | None => ()
        }
      }
      if remaining.contents != 0 {
        throw(
          Seed.Failed(
            `${remaining.contents->Int.toString} item(s)/object(s) remain after the wipe — re-run to finish.`,
          ),
        )
      }

      Console.log("")
      Console.log(`Reset complete — the selected scope of "${stack}" reads empty and is re-seedable.`)
      NodeProcess.exit(0)
    } catch {
    | Seed.Failed(message) =>
      Seed.Prompt.close()
      Console.error("")
      Console.error(`Reset aborted — ${message}`)
      NodeProcess.exit(1)
    | exn =>
      Seed.Prompt.close()
      Console.error("")
      Console.error("Reset aborted with an unexpected error:")
      Console.error(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"))
      NodeProcess.exit(1)
    }
  }
  go()->ignore
}
