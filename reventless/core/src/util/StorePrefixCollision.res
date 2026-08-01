// Two declared object stores a platform cannot keep apart.
//
// Lives in core, not in an adapter: the rule is about a namespace, not about a
// cloud. The deployed platform enforces it as a gate before it provisions
// anything, and the local platform reports it at composition — one predicate, so
// the two cannot drift into disagreeing about what a collision is.

/** One declared store as the collision check sees it: its qualified key and the
    prefix its objects are rooted at.

    `site` is the `{component}.{field}` that declared it, when the caller has it.
    The deploy-time capability list does not — `Platform.capability` carries only
    `{plugin, store}`, and the generator renders provenance as comments in the
    platform's generated capability file — so the deploy message points a reader
    there instead of inventing a site it cannot know. */
type declaredStore = {
  qualified: string,
  prefix: string,
  site?: string,
}

/**
Two stores a platform cannot keep apart.

The prefix is a **platform-global** namespace, not a per-bucket one: exactly one
distribution fronts every store bucket, and it takes one cache behavior per
served prefix. So two stores on one prefix are unroutable in either layout — a
shared bucket lists the prefix twice, a per-store layout lists it once per
bucket, and CloudFront accepts neither. Left to the deploy, that surfaces as an
AWS error naming a path pattern rather than the two plugins that caused it,
minutes in, after the silent damage below has already been provisioned:
intermixed objects, and a presign grant scoped by prefix that reaches into both
stores at once.

Compares **prefixes, not store names**, and on **containment, not equality**:
`a` collides with `a/b`, because a store rooted at `a` encloses one rooted at
`a/b` for serving, for IAM and for wiping alike. Both choices are what let a
qualified prefix scheme relax this check without rewriting it — a qualified
prefix simply stops colliding.
*/
type collision = {
  first: declaredStore,
  second: declaredStore,
  /** True when the first prefix encloses the second rather than equalling it. */
  nested: bool,
}

let collisionsFor = (~stores: array<declaredStore>): array<collision> =>
  stores->Array.reduceWithIndex([], (found, a, i) =>
    stores->Array.reduceWithIndex(found, (found, b, j) =>
      if j <= i || a.qualified == b.qualified {
        found
      } else if a.prefix == b.prefix {
        Array.concat(found, [{first: a, second: b, nested: false}])
      } else if b.prefix->String.startsWith(a.prefix ++ "/") {
        Array.concat(found, [{first: a, second: b, nested: true}])
      } else if a.prefix->String.startsWith(b.prefix ++ "/") {
        Array.concat(found, [{first: b, second: a, nested: true}])
      } else {
        found
      }
    )
  )

/** The refusal text. Names both declaration sites, because "two stores collide"
    without them sends a reader hunting through every schema in the platform —
    and states both remedies, because a cross-plugin store is legitimate when the
    `@storageRef` annotation qualifies it, and only accidental when it does not. */
let collisionMessage = (c: collision): string => {
  let site = (s: declaredStore) =>
    switch s.site {
    | Some(site) => `  ${s.qualified} — declared at ${site}\n`
    | None => ""
    }
  let sites = site(c.first) ++ site(c.second)
  let where = sites == ""
    ? `  Both keys appear in the platform's generated capability file, which records each ` ++
      `declaring component and field as a comment.\n`
    : sites
  if c.nested {
    `Object store "${c.first.qualified}" is rooted at "${c.first.prefix}/", which encloses ` ++
    `"${c.second.qualified}" at "${c.second.prefix}/".\n` ++
    where ++
    `  One store's objects would sit inside the other's — for serving, for upload grants and ` ++
    `for a store wipe alike. Rename one of them.`
  } else {
    `Object stores "${c.first.qualified}" and "${c.second.qualified}" both root their objects ` ++
    `at "${c.first.prefix}/".\n` ++
    where ++
    `  A platform serves one cache behavior per prefix and scopes upload grants by prefix, so ` ++
    `two stores cannot share one.\n` ++
    `  Rename one store, or — if they were meant to be one shared store — qualify the ` ++
    `\`@storageRef\` annotation with the owning plugin.`
  }
}

