# Reventless Conventions

## Compiler Warnings

Zero warnings required. After every build, verify with:
```bash
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

Fix all warnings before committing.

## Commit Messages

Use Conventional Commits for automated versioning:
- `feat:` — new feature (minor version bump)
- `fix:` — bug fix (patch version bump)
- `feat!:` or `fix!:` — breaking change (major version bump)
- `chore:` — maintenance, no changelog entry
- `docs:` — documentation only

Dependency updates: use `fix(deps):` for security/functional impact, `chore(deps):` for routine patches.

## Package Placement

| Folder | Purpose |
|--------|---------|
| `rescript/` | ReScript bindings for JS/npm libraries |
| `reventless/` | Reventless framework and extension packages |
| `examples/` | Example applications |
| `packages/` | Build tooling and documentation only |

Always place new packages in the correct root folder.

## Component Structure Pattern

Framework components follow:
- `Component.res` — type definitions and outputs
- `Component_Builder.res` — factory using functors
- `Component_Adapter.res` — provider-agnostic interface (optional)
- `Component_Operations.res` — runtime logic (optional)
- `Component_Callback.res` — runtime handlers (optional)
