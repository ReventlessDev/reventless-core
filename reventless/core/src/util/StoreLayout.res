// Where a declared object store's keys are rooted.
//
// Lives in core beside StorePrefixCollision, and for the same reason: the rule
// is about a namespace, not about a cloud. The deployed platform roots an S3
// store's keys here, the local platform roots its filesystem store's keys here,
// and a reset attributes an object to the plugin that declared its store by
// reading the prefix back off the key. Three readers of one rule — so it is one
// function, not three strings that happen to agree today.
//
// Qualifying by plugin is what makes the prefix an identity rather than a label:
// two plugins may both declare a store called `images`, and only the qualified
// form keeps their objects apart (which is the collision StorePrefixCollision
// refuses when it cannot).

/** The prefix a store's object keys are rooted at: `{plugin}/{store}`.

    A stored ref is independent of whether the store got its own bucket or a
    prefix inside a shared one — refs live in an append-only log, so one that
    encoded its physical layout would be unrewritable and environment-specific. */
let keyPrefixFor = (~plugin: string, ~store: string): string => `${plugin}/${store}`

/** The same prefix from the qualified `{plugin}.{store}` key that a
    `pluginStructure.requiredStores` entry carries and that the `Upload_Presign`
    mutation's `store` argument names.

    Splits on the FIRST `.` — a store name may contain dots, a plugin name may
    not. An unqualified key (no `.`) is returned as-is rather than guessed at:
    it is not a `{plugin}.{store}` and inventing a plugin for it would attribute
    objects to a plugin that never declared them. */
let prefixOfQualified = (qualified: string): string =>
  switch qualified->String.indexOfOpt(".") {
  | Some(i) =>
    keyPrefixFor(
      ~plugin=qualified->String.slice(~start=0, ~end=i),
      ~store=qualified->String.slice(~start=i + 1, ~end=qualified->String.length),
    )
  | None => qualified
  }
