# Analysis: Eliminating `moduleUrl` Raw JavaScript

## Problem

Every spec, behavior, and mapping module in the framework must declare:

```rescript
let moduleUrl: string = %raw(`import.meta.url`)
```

This is raw JavaScript embedded in ReScript — the only instance of `%raw` in application code. There are **600+ declarations** across the codebase. It's boilerplate, error-prone (forgetting it causes runtime failures), and aesthetically unpleasant.

## Why `moduleUrl` Exists

At deploy time, the AWS builders need to know the **npm specifier** of each spec module (e.g., `@reventlessdev/catalog/src/Category.res.mjs`). This specifier is:

1. Stored in the Lambda's `HANDLER_CONFIG` environment variable
2. Used at Lambda runtime to `import(specModulePath)` the spec module dynamically
3. Used to construct the code asset (esbuild bundles the spec from its package root)

The chain:

```
import.meta.url → file:///absolute/path/to/Category.res.mjs
       ↓
Util_Bundle.getModuleSpecifier() → @reventlessdev/catalog/src/Category.res.mjs
       ↓
PluginRuntime_Builder.register() → stored in HANDLER_CONFIG
       ↓
Lambda runtime: import("@reventlessdev/catalog/src/Category.res.mjs")
```

The problem is that the framework needs the npm specifier, but ReScript has no compile-time mechanism to derive it.

## Where `moduleUrl` Is Required

10 spec types in `reventless-spec` + 8 types in `reventless-infra` require `let moduleUrl: string`:

| Module Type | Package |
|---|---|
| `Aggregate.Spec`, `ReadModel.Spec`, `Behavior.T` | reventless-spec |
| `StateChangeSlice.Spec`, `StateViewSlice.Spec` | reventless-spec |
| `AutomationSlice.Spec`, `OutboundTranslationSlice.Spec`, `InboundTranslationSlice.Spec` | reventless-spec |
| `SideEffect.T`, `Projection.Mappings` | reventless-spec |
| `ExtensionMapping.Spec`, `ExtensionPointMapping.T` | reventless-infra |
| `ExtensionPoint.Spec`, `Extension.Blueprint` | reventless-infra |

## Who Consumes `moduleUrl`

**Only the AWS builders** read `moduleUrl` — specifically `Util_Bundle.getModuleSpecifier(Spec.moduleUrl)` in files like:

- `Aggregate_Builder_Single.res`
- `ReadModel_Builder_Single.res`
- `StateChangeSlice_Builder.res`
- `ExtensionPoint_Builder.res`
- etc.

The local platform ignores `moduleUrl` entirely. It's a deploy-time-only concern.

---

## Approaches

### A: PPX That Injects the npm Specifier at Compile Time

A ReScript PPX has access to the source file path via `Location.input_name` in the AST. A PPX could:

1. Read the current file's path from the AST location
2. Walk up to find the nearest `package.json` (same logic as `getModuleSpecifier`, but at compile time)
3. Compute the npm specifier: `packageName + "/" + relativePath.replace(".res", ".res.mjs")`
4. Inject `let moduleUrl = "computed-specifier"` as a pure string literal

**Usage:**

```rescript
// Before:
let moduleUrl: string = %raw(`import.meta.url`)

// After (with PPX attribute):
@moduleUrl  // PPX generates: let moduleUrl = "@reventlessdev/catalog/src/Category.res.mjs"
```

Or even implicit — the PPX detects modules that satisfy a spec type and injects `moduleUrl` automatically.

**Pros:**
- Eliminates `%raw` entirely
- Pure compile-time — no runtime overhead
- The computed specifier is a string literal, visible in the compiled output

**Cons:**
- Requires a custom PPX (or extending sury-ppx)
- PPX must have filesystem access to walk up and find `package.json` — non-standard for a PPX
- Path derivation at PPX time uses the source `.res` path, needs to map to `.res.mjs` output
- Build cache invalidation: if package.json name changes, PPX output must change too

**Feasibility:** Medium-high. PPX filesystem access is unusual but not prohibited. The sury-ppx already does I/O-like operations.

---

### B: ReScript Compiler `__FILE__` + Runtime Derivation

OCaml has `__FILE__` and `__MODULE__`. ReScript doesn't expose these, but a PPX can inject the equivalent:

```rescript
@moduleUrl  // PPX injects: let moduleUrl = "src/Category.res"
```

Then change `getModuleSpecifier` to accept a relative file path instead of a `file://` URL, and prepend the package name at deploy time:

```rescript
// In the AWS builder:
let specifier = packageName ++ "/" ++ Spec.moduleUrl.replace(".res", ".res.mjs")
```

**But:** The builder still needs to know `packageName`. Options:
- Read it from an environment variable set by the build system
- Derive it from the monorepo's lerna/npm workspace config
- Have the plugin pass its package name to `Plugin.make`

**Pros:**
- Simpler PPX (just injects `__FILE__` equivalent, no filesystem walk)
- No raw JavaScript

**Cons:**
- Still requires a PPX
- Package name derivation moves to the builder, adding complexity there
- Package name must be available at deploy time (it already is — Pulumi runs in the monorepo)

**Feasibility:** High. The PPX is simpler than Approach A, and the builder already has access to the package.json at deploy time.

---

### C: Derive at Builder Call Site — No `moduleUrl` in Specs

Remove `moduleUrl` from all spec module types entirely. Instead, the AWS builder derives the specifier from the module itself.

**How?** In JavaScript/ESM, when a module is imported, the importing file knows the specifier it used. The ReScript compiler outputs import statements like:

```javascript
import * as Category from "@reventlessdev/catalog/src/Category.res.mjs";
```

If we could access this import specifier at runtime... we can't directly. But we CAN use a different trick:

**Option C1: `import.meta.url` at the BUILDER level only**

The plugin file (`CatalogPlugin.res`) already has `import.meta.url`. Since it imports all specs, its `import.meta.url` gives us the plugin package root. Combined with the spec's relative path (derivable from the import graph), we could reconstruct the specifier.

But: ReScript first-class modules don't carry their import paths.

**Option C2: `import.meta.resolve()` at deploy time**

```javascript
const specUrl = import.meta.resolve("@reventlessdev/catalog/src/Category.res.mjs")
```

This requires knowing the specifier to begin with — circular.

**Option C3: One `moduleUrl` per PLUGIN, not per spec**

Instead of every spec declaring `moduleUrl`, only the plugin declares it:

```rescript
// CatalogPlugin.res
let moduleUrl: string = %raw(`import.meta.url`)
```

The builder derives all spec paths relative to the plugin's package root:

```rescript
// Framework figures out: plugin package = @reventlessdev/catalog
// Then: spec path = @reventlessdev/catalog/src/Category.res.mjs
```

**But:** This only works if specs are in the same package as the plugin. Cross-package specs (like `reventless-spec` types) need their own package name. Actually — spec packages are imported by the plugin, so their package names are known to npm. The builder could use `require.resolve` to find them.

**Pros:**
- Eliminates `moduleUrl` from all specs and mappings
- Single `moduleUrl` per plugin (or even derived from `Plugin.make` name)
- Massive boilerplate reduction

**Cons:**
- Complex derivation logic in the builder
- Cross-package specs (spec packages imported by plugins) need special handling
- Fragile if the monorepo structure changes

**Feasibility:** Medium. The derivation is complex but the payoff is enormous (600+ lines removed).

---

### D: Convention-Based — `name` Field Is Enough

Every spec already has `let name: string` (e.g., `"Category"`, `"Product"`). If the framework enforced a convention:

- Spec file MUST be at `src/<ComponentType>/<Name>.res` within its package
- Package name is known from the plugin's package.json

Then the builder can derive:

```
specifier = pluginPackageName + "/src/" + componentDir + "/" + Spec.name + ".res.mjs"
```

**Pros:**
- Zero additional fields needed
- Convention over configuration

**Cons:**
- Assumes rigid directory structure — breaks if someone puts a spec in a nested folder or uses a different name
- Doesn't work for cross-package specs
- Doesn't work for behaviors, projections, or mappings (which don't have a 1:1 name-to-file mapping)

**Feasibility:** Low. Too brittle for a general solution.

---

### E: Build Plugin That Generates a Module Map

A post-compilation step scans the ReScript output and generates a mapping file:

```javascript
// generated: ModuleMap.res.mjs
export const moduleMap = {
  "Category": "@reventlessdev/catalog/src/Category.res.mjs",
  "Product": "@reventlessdev/catalog/src/Product.res.mjs",
  // ...
}
```

The builder looks up `Spec.name` in this map instead of reading `Spec.moduleUrl`.

**Pros:**
- No PPX, no `%raw`, no `moduleUrl` in specs
- Works with any directory structure

**Cons:**
- Extra build step
- Map must be regenerated on every change
- Name collisions across packages
- Must be integrated into the build pipeline

**Feasibility:** Medium. Clean but adds build complexity.

---

### F: PPX Attribute on the Module Declaration (Recommended)

Extend sury-ppx (or create a companion PPX) with a `@specModule` attribute:

```rescript
// Before:
let name = "Category"
let moduleUrl: string = %raw(`import.meta.url`)
@schema type command = ...

// After:
@@specModule  // file-level attribute
let name = "Category"
@schema type command = ...
// moduleUrl is auto-injected by the PPX
```

The PPX:
1. Sees `@@specModule` at the top of the file
2. Gets the source file path from `Location.input_name` (e.g., `src/Aggregate/Category.res`)
3. Walks up from the **source file** (not build output) to find `package.json`
4. Computes: `packageName + "/" + relativePath` with `.res` → `.res.mjs` suffix
5. Injects `let moduleUrl: string = "computed-specifier"` into the AST

Since the PPX runs at compile time and has filesystem access, this is deterministic and fast.

**For the `{let moduleUrl: string = %raw(\`import.meta.url\`)}` inline configs** (e.g., in `Platform.ExtensionPoint.Make(..., {let moduleUrl = ...})`), the PPX could provide a function-like syntax:

```rescript
// Before:
module EP = Platform.ExtensionPoint.Make(Mapping, {let moduleUrl: string = %raw(`import.meta.url`)})

// After:
module EP = Platform.ExtensionPoint.Make(Mapping, {let moduleUrl = @@specModule})
// Or: the Platform.Make functor no longer requires moduleUrl at all (derived from Mapping.moduleUrl)
```

**Pros:**
- Eliminates all `%raw` from application code
- Opt-in per file (explicit)
- Deterministic compile-time computation
- No runtime overhead
- sury-ppx already processes these files — can be extended

**Cons:**
- PPX filesystem access (reading package.json) is non-standard
- Must handle edge cases (workspace hoisting, symlinks)

**Feasibility:** High. This is the cleanest solution.

---

## Recommendation

**Short term (Approach F):** Add a `@@specModule` PPX attribute that auto-injects `moduleUrl` at compile time. This eliminates `%raw` from all ~600 declarations with minimal framework changes.

**Long term (Approach C3 evolution):** Move toward having only the Plugin (or Platform) know its package root, and derive all spec paths at deploy time. This would remove `moduleUrl` from spec types entirely — but requires more invasive framework changes.

## Impact

| Approach | User-facing change | Framework change | `%raw` eliminated |
|---|---|---|---|
| **F (PPX)** | Replace `let moduleUrl = %raw(...)` with `@@specModule` | Extend PPX, no runtime changes | Yes |
| **C3 (plugin-level)** | Remove `moduleUrl` from all specs | Rework AWS builder derivation | Yes |
| **B (__FILE__ PPX)** | Replace `%raw` with PPX attribute | Builder changes for package name | Yes |
| **A (full PPX)** | Same as F but with filesystem walk | Custom PPX | Yes |
