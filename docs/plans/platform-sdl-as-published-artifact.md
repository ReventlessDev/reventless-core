# The platform SDL as a published artifact

## The problem

`platform-api.graphql` — the platform admin API a UI shell compiles its queries
against — is snapshotted in two places by hand: as a golden here, and again as a
committed copy in the shell's own repo. The two are the same bytes, produced by
introspecting the same server, and nothing keeps them together.

So a change to the contract fails this repo's `check:graphql` with a message that
ends in an instruction to go and do something in another repo. The instruction is
the only mechanism: no check verifies it happened, because the CI that would
verify it does not check that repo out. Left undone, the shell keeps compiling
green against a schema no server serves and fails against a real backend.

Automating the copy was considered and rejected — it removes the fiddly half
(boot a platform on the right port in the right repo) and leaves the half that
matters (notice that it is stale at all). The copy is the problem, not the
copying.

## The shape

The platform admin API is framework-owned, not example-owned: all 42 types in the
golden are `Platform_*` or framework-level (`CommandResult`, `PageInfo`,
`SortOrder`, …), with nothing from the hybrid example's plugins. It is generated
by booting that example only because an example is the cheapest way to get a
platform serving.

So publish it. `reventless-spec` ships `schema/platform-api.graphql`; the shell
takes a devDependency on the spec package and points Relay at the file inside
`node_modules`. The shell stops committing a snapshot, so there is nothing to
refresh — the schema arrives with a dependency bump.

Lerna versions this repo independently off conventional commits, so the spec
package bumps exactly when its contents change. The version a shell pins **is**
the contract version.

This also fixes the lockstep trap the contract guide already warns about from the
other direction. A hand-written query is a lockstep change with the platform:
GraphQL rejects a whole document that selects an undeclared field, so a shell
ahead of its platform boots to nothing rather than degrading. A snapshot copied
from a working tree lets Relay compile green against a platform nobody has
deployed. A snapshot that can only arrive by dependency bump cannot.

## Verified up front

- **Relay accepts this repo's SDL as-is.** Pointed the shell's `relay.config.js`
  at `examples/online-shop-hybrid/schema/platform-api.graphql` and ran
  `rescript-relay-compiler`: 6 reader / 6 normalization / 6 operation text, no
  errors, and **zero** churn in `src/__generated__`. The two files differ only by
  a leading `directive @oneOf on INPUT_OBJECT` — graphql 16 here treats it as
  built-in and omits it, graphql 15 in the shell does not recognise it as
  built-in and prints it. It is declared and never used, so nothing depends on it.
- **The subpath resolves.** `reventless-spec` declares no `exports` map, so
  `@reventlessdev/reventless-spec/schema/platform-api.graphql` is importable.
- **It publishes.** No `files` allowlist, and `.npmignore` does not exclude a new
  `schema/` directory.
- **No peer conflict.** The spec package peer-depends on `rescript 12.3.0`; the
  shell is already on `^12.3.0`.

## Steps

### Core (this repo) — done

1. ✅ `git mv examples/online-shop-hybrid/schema/platform-api.graphql
   reventless/spec/schema/platform-api.graphql`. `domain-api.graphql` stays in
   the example — it is generated from that example's plugin specs and is
   genuinely example-owned.
2. ✅ `scripts/CheckGraphqlContract.res`: each contract carries its own golden
   directory rather than sharing one `goldenDir`, so the platform half writes
   into the spec package and the domain half stays put.
3. ✅ Same file: fixed the drift report. `firstDiff` line-aligned the two files,
   so a pure insertion reported the first *shifted* line as a mismatched pair —
   the `ownerField` change printed `golden: references: …` against
   `actual: ownerField: String`, a replacement that never happened. Now a
   multiset difference, reporting each line one side has and the other does not,
   named by the declaration it sits in. Re-running the original failure prints:

   ```
   drift in platform-api.graphql
     + Platform_CommandDef.ownerField: String
     + Platform_ReadSideDef.ownerField: String
   ```

   and a rename prints the matching `-` line.
4. ✅ Same file: the drift epilogue no longer ends in an instruction to go and
   regenerate something in another repo. Refreshing the golden is the whole job
   on this side.
5. ✅ Docs: `examples/online-shop-hybrid/schema/README.md` rewritten for the
   split home, and a new `reventless/spec/schema/README.md` covers why the
   contract is published and that it is generated, not written.

Verified: `pnpm run check:graphql` green against both new homes, zero compiler
warnings, and `npm pack --dry-run` in `reventless/spec` lists
`schema/platform-api.graphql` (6.9 kB) in the tarball.

Push. The alpha auto-release publishes a spec version carrying the SDL.

### Shell (other repo, after that version is on npm)

6. devDependency on the published `@reventlessdev/reventless-spec`.
7. `relay.config.js`: `schema` → `require.resolve` of the package subpath.
8. `git rm` the committed `schema.graphql`.
9. `CheckGraphqlSchema.res`: read the SDL from the package instead of the
   committed file. The **documents** half is unchanged in spirit — it still
   validates the hand-written queries no compiler sees, now against the pinned
   contract. The **snapshot** half changes meaning: it stops asking "is my file
   stale?" and starts asking "is the platform I am pointed at the one I am pinned
   to?" — a version-skew check. `check:graphql:update` goes away; there is no
   writer left.
10. Add the spec package to `cross-repo-link.config.json.example`, so developing
    against an unpublished contract is the existing `pnpm link:on` overlay rather
    than a special case.
11. Update the contract guide, and re-run `pnpm run relay` (expected no-op).

## Sequencing

Step 6 is blocked on step 5 publishing — the shell cannot pin a version that does
not exist. Until then the overlay from step 10 covers local work. The shell keeps
its committed snapshot working the whole time; nothing breaks mid-flight.

## Open

- Whether the domain half's golden earns the same treatment. It does not today —
  no client compiles against it, the shell builds those queries at runtime from
  the component-definitions manifest, so the golden is a codegen report rather
  than a contract anyone pins.
