# AppSync Resolver JavaScript-as-Strings Analysis

## Summary

The AppSync resolver code in `rescript-pulumi-aws` and `reventless-aws` embeds JavaScript source code as ReScript strings. This is intentional and necessary — the strings are the resolver code itself, not glue or boilerplate.

## Why It Is Necessary

AppSync JS resolvers run inside **AWS's APPSYNC_JS runtime** — a restricted JavaScript engine managed entirely by AWS. To deploy a resolver, you upload its source code as a string via the AWS API. Pulumi stores this string and sends it to AWS, which executes it inside AppSync at query time.

```
ReScript (deploy-time, on developer machine)
  → generates JS string
  → Pulumi sends string to AWS API
  → AppSync stores + executes string at query time
```

**ReScript cannot replace this for three reasons:**

1. **APPSYNC_JS is not Node.js** — it is a separate JS engine with a restricted subset of JavaScript and no npm module resolution.
2. **`@aws-appsync/utils` is AppSync-internal magic** — `import { util } from '@aws-appsync/utils'` is resolved by the AppSync runtime, not by an npm install. There is no real package to compile against.
3. **AWS requires source code as a string** — the AppSync resolver API accepts source code, not a binary or function reference.

This is the standard pattern across all AWS IaC tools (CDK, Pulumi, Terraform, SST) — all embed AppSync resolver code as strings.

## What the ReScript Code Actually Does

`AppSync_Resolver_Functions.res` is a **deploy-time template library**. The ReScript runs in Pulumi (on the developer's machine) to:

- Parameterize JS resolver strings with field names, index names, table names at deploy time via string interpolation
- Compose full resolvers from shared response snippets (`resultResponseCode`, `firstResultResponseCode`, `resultListResponseCode`)
- Wrap strings in `Pulumi.Input.t<string>` so Pulumi can wire them with other infrastructure outputs (e.g. a table name resolved from a `Pulumi.Output.t<string>`)

## Statistics

**File:** `rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res`

| Metric | Count |
|--------|-------|
| Total `let` bindings | 41 |
| Parameterized resolver templates (take arguments) | 23 |
| Static string values | 18 |
| Wrapped as `Pulumi.Input.t<string>` | 32 |
| Raw strings (building blocks / returned unwrapped) | 9 |
| Distinct `export function request` definitions | 27 |
| Distinct `export function response` definitions | 12 |
| **Total JS function definitions in file** | **39** |

**Effective resolver count at deploy time** is higher than 39: the 3 shared response snippets (`resultResponseCode`, `firstResultResponseCode`, `resultListResponseCode`) are interpolated into ~20 other resolver templates via `${...}`, so approximately 50+ JS function bodies are deployed per resolver set.

**Additional file:** `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` adds one more inline JS resolver string (`interceptorCode`) for the optional query interceptor pipeline function.

## Could the JS Be Replaced?

**No meaningful alternative exists.** The closest option would be to store each resolver in a separate `.js` file and read it as a string at deploy time, but:

- You would lose parameterization (field names, index names interpolated at deploy time)
- You would gain more files with less type safety
- The end result sent to AWS is identical — still a JS string

The current string-template approach is actually idiomatic for this use case. It gives compile-time ReScript type checking on the parameters while keeping the resolver logic close to where it is configured.
