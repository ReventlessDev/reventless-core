# The platform admin API contract

`platform-api.graphql` is the SDL of the platform admin API — the `Platform_*`
half of what a UI shell talks to. It is **published with this package**, and a
shell compiles its Relay queries against it as a dependency rather than keeping a
copy of its own.

That is the whole point of it living here. A snapshot copied by hand into another
repo rots silently: the copy keeps compiling green against a schema no server
serves, and the shell fails only against a real backend. A snapshot that arrives
by dependency bump cannot get out of step with a version. Lerna versions this
repo off conventional commits, so this package bumps exactly when its contents
change — **the version a shell pins is the contract version it compiles
against.**

That also keeps a shell from running ahead of a platform. A hand-written GraphQL
document is a lockstep change, not an additive one: the server rejects the whole
document when it selects a field the schema does not declare, so a shell ahead of
its platform boots to nothing rather than degrading. Pinning a published version
means the contract a shell compiles against is one that exists.

## It is generated, not written

Written by `pnpm run check:graphql` from the repo root, which boots the hybrid
example's local platform and introspects it. Do not edit it by hand.

The example is only a vehicle — nothing example-specific reaches this file. Every
type in it is `Platform_*` or framework-level (`CommandResult`, `PageInfo`,
`SortOrder`, …); no plugin of that example contributes anything. Its sibling
golden, `domain-api.graphql`, is the plugin-generated half and stays with the
example that produces it.

Sorted through `lexicographicSortSchema`, so it is a function of the schema alone
— the platform builds its type map from dicts, and unsorted output would diff on
iteration order rather than on a real contract change.

## Changing it

Change the platform, then run `pnpm run check:graphql:update` and commit this
file alongside the change that moved it. The diff is the review artifact for a
wire-shape change.
