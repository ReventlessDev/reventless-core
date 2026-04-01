---
description: Validate Reventless project structure, naming conventions, schema annotations, and compilation
---

# Validate Reventless Project

Validates a Reventless project for correctness, completeness, and convention compliance.

## Checks Performed

### 1. Structure Validation

- All plugin packages have `package.json` and `rescript.json`
- Plugin composition root exists (`*Plugin.res` with `Make` functor)
- Platform `Main.res` exists and references all plugins
- Spec packages exist for plugins with extension points
- Directory structure follows conventions (Aggregate/ or Entity/StateChangeSlice/)

### 2. Naming Conventions

- Aggregates use singular nouns
- ReadModels/StateViewSlices use plural nouns or descriptive names
- Commands are imperative (Add, Update, Place)
- Events are past tense (Added, Updated, Placed)
- Extension points use dotted names ("Plugin.Entity")
- Plugin namespaces follow `{Plugin}Plugin` pattern
- Spec namespaces follow `{Plugin}Spec` pattern

### 3. Schema Annotations

Search all `.res` files for:
- `type command` without `@schema` → error
- `type event` without `@schema` → error
- `type error` without `@schema` → error
- `type state` in read models/view slices without `@schema` → error
- DCB entity ID fields without `@s.matches(DcbTag.string)` → error
- `@s.matches` on field name instead of type expression → error

### 4. Module URL

Verify `let moduleUrl: string = %raw(\`import.meta.url\`)` is present in:
- All aggregate spec files
- All StateChangeSlice files
- All EP mapping files
- All Extension mapping files
- All SideEffect handler files

### 5. Plugin Composition Completeness

- All aggregate/slice modules are registered in `Plugin.make(...)`
- All read model/view slice modules are registered
- Extension points and extensions are wired correctly
- No orphaned component files (defined but not wired)

### 6. Build Verification

```bash
npm run build 2>&1 | grep -E "Warning|warning|error|Error"
```

Must produce zero warnings and zero errors.

### 7. Test Execution

```bash
npm test
```

All tests must pass.

## Output Format

Report findings as:
- Passed checks (count)
- Warnings (non-blocking, suggestions)
- Errors (must fix before deployment)

For each error, include:
- File path and line number
- What's wrong
- How to fix it
