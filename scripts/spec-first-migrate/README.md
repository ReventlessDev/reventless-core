# spec-first-migrate

Phase 4 of [`docs/plans/spec-first-split-infrastructure.md`](../../docs/plans/spec-first-split-infrastructure.md).

Splits a merged DCB slice file (`X.res` with `@@reventless.spec`) into:

- **`X.res`** — Spec only (keeps `@@reventless.spec`).
- **`X_<Kind>.res`** — Implementation only (gets `@@reventless.<kind>`).

Slice folder → implementation kind mapping:

| Folder                       | Implementation kind | File attribute              |
|------------------------------|---------------------|-----------------------------|
| `StateChangeSlice/`          | `Behavior`          | `@@reventless.behavior`     |
| `StateViewSlice/`            | `Projection`        | `@@reventless.projection`   |
| `AutomationSlice/`           | `Automation`        | `@@reventless.automation`   |
| `InboundTranslationSlice/`   | `Translation`       | `@@reventless.translation`  |
| `OutboundTranslationSlice/`  | `Translation`       | `@@reventless.translation`  |

Per-kind binding classification follows D2 in the plan.

## Usage

```bash
# Dry-run on a single file or directory
node scripts/spec-first-migrate/spec-first-migrate.mjs --dry-run examples/online-shop-dcb/

# Migrate a single file
node scripts/spec-first-migrate/spec-first-migrate.mjs examples/online-shop-dcb/catalog/src/Category/StateChangeSlice/ArchiveCategory.res

# Migrate every slice file under a tree, with a JSON report
node scripts/spec-first-migrate/spec-first-migrate.mjs \
  --report /tmp/migrate-report.json \
  examples/online-shop-dcb/
```

Flags:

- `--dry-run` / `-n` — print planned splits without writing files.
- `--report <path>` — write a structured JSON report describing every result.
- `<file-or-dir>...` — one or more `.res` files or directories. Directories
  are walked recursively for `.res` files; `node_modules/` and `lib/` are
  skipped automatically.

## Idempotence

Running the script on already-split files is a no-op:

- An implementation file (carries `@@reventless.behavior` / `.projection` /
  `.automation` / `.translation`) is skipped.
- A spec file whose sibling `X_<Kind>.res` already exists is skipped.
- A file outside any recognised slice folder is skipped.

## Self-test

```bash
node scripts/spec-first-migrate/spec-first-migrate.test.mjs
```

The self-test covers all 5 slice kinds. For each kind it asserts:

- the spec file keeps `@@reventless.spec` and the file-header comments;
- the impl file gets the right `@@reventless.<kind>` attribute;
- every spec binding lands in the spec file and every impl binding in the
  impl file;
- no spec binding leaks into the impl file (and vice versa);
- no warnings are emitted on canonical input;
- **byte-stability**: re-splitting the spec output is a no-op (`split(spec)`
  produces the same `spec` and an empty impl);
- **round-trip stability**: split → re-merge → split produces byte-stable
  output.

## Phase 5 dependency note

Migrating the actual examples (Phase 5 of the plan) is gated on Phase 3b,
which adds PPX-injected type annotations to resolve the constructor-shadowing
that arises when `consumedEvent` and `event` share constructor names. Without
Phase 3b, splitting a `StateChangeSlice` produces a structurally correct pair
of files but the implementation file's `evolve` will fail to type-check
because `open Spec` brings the `event` constructors into scope after
`consumedEvent` (later declaration wins).

The split itself is correct in either case — Phase 3b is what makes the
migrated code compile.
