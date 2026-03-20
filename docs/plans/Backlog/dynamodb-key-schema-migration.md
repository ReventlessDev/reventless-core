# Plan: Migrate DynamoDB Table bindings from hashKey/rangeKey to keySchema

## Status: BLOCKED

**Blocked on**: The Pulumi AWS Node.js SDK (`@pulumi/aws`) does not expose a `keySchema` property on `TableArgs`. Checked both v7.19.0 (our current version) and the current master branch — neither has it. The deprecation warnings originate from the underlying Terraform AWS provider, but the Pulumi SDK has not yet surfaced the replacement field.

**Action**: Monitor [pulumi/pulumi-aws](https://github.com/pulumi/pulumi-aws) releases for a version that adds `keySchema` to `TableArgs`. The warnings are cosmetic and do not affect functionality.

## Problem

Pulumi AWS provider now emits deprecation warnings on every DynamoDB table:

```
warning: hash_key is deprecated. Use key_schema instead.
warning: range_key is deprecated. Use key_schema instead.
```

The `hashKey`/`rangeKey` fields on `aws:dynamodb:Table` are deprecated in favor of the `keySchema` array. Our `rescript-pulumi-aws` bindings and all DynamoDB table creation utilities use the old fields.

## Investigation Results (2026-03-20)

1. **`keySchema` does not exist in the Pulumi AWS Node.js SDK** — not in v7.19.0, not on master. The `TableArgs` interface only has `hashKey` and `rangeKey`.
2. **GSI/LSI types** also still use `hashKey`/`rangeKey` — no `keySchema` equivalent there either.
3. **Attempting to pass `keySchema` directly** results in the provider ignoring it, then erroring with "all attributes must be indexed. Unused attributes" because it doesn't see any key definition.
4. **The deprecation warnings are "verification warnings"** from the Terraform provider layer — they appear when reading existing state, not just when creating new resources.

## Scope (when unblocked)

### Binding layer (`rescript/rescript-pulumi-aws/src/DynamoDb/DynamoDb_Table.res`)

1. **`args` type** — replace `hashKey`/`rangeKey` with `keySchema`:
   ```rescript
   // Old:
   hashKey: Pulumi.Input.t<string>,
   rangeKey?: Pulumi.Input.t<string>,

   // New:
   type keySchemaEntry = { attributeName: string, keyType: string }  // "HASH" | "RANGE"
   keySchema: Pulumi.Input.t<array<keySchemaEntry>>,
   ```

2. **`t` output type** — keep `hashKey`/`rangeKey` on outputs (provider still returns them).

3. **`globalSecondaryIndex` / `localSecondaryIndex` types** — check if GSI/LSI definitions also switched to `keySchema`.

### Utility layer (`reventless/reventless-aws/src/util/`)

4. **`Util_DynamoDb.makeTableArgs`** — convert hardcoded `hashKey: "id"` + optional `~rangeKey` to `keySchema` array construction. Keep the `~rangeKey` parameter signature for callers.

5. **`Util_DynamoDbStream.makeTable`** — delegates to `Util_DynamoDb.makeTableArgs`, no direct changes needed.

6. **`Util_DynamoDb.toResolvedTableOutput`** — reads `table.hashKey`/`table.rangeKey` from outputs. No change (outputs still available).

### Adapter layer — no changes needed (callers pass `~rangeKey` to utility functions)

### Runtime layer — no changes needed (uses own `resolvedTable` record fields, not Pulumi inputs)

## Risk

- **Low risk**: This is a field rename in Pulumi inputs. The DynamoDB tables themselves don't change.
- **Pulumi state**: Verify with `pulumi preview` before applying — no table replacement expected.
