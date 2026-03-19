# Plan: Migrate DynamoDB Table bindings from hashKey/rangeKey to keySchema

## Problem

Pulumi AWS provider now emits deprecation warnings on every DynamoDB table:

```
warning: hash_key is deprecated. Use key_schema instead.
warning: range_key is deprecated. Use key_schema instead.
```

The `hashKey`/`rangeKey` fields on `aws:dynamodb:Table` are deprecated in favor of the `keySchema` array. Our `rescript-pulumi-aws` bindings and all DynamoDB table creation utilities use the old fields.

## Scope

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

2. **`t` output type** — the provider still returns `hashKey`/`rangeKey` as outputs. Check whether the new provider version also returns `keySchema` outputs, or if we keep reading the old output fields (which are typically still populated even when deprecated on input).

3. **`globalSecondaryIndex` / `localSecondaryIndex` types** — these also use `hashKey`/`rangeKey`. Check if GSI/LSI definitions also switched to `keySchema`.

### Utility layer (`reventless/reventless-aws/src/util/`)

4. **`Util_DynamoDb.res`** — `makeTable` and `makeTableWithIndex` pass `hashKey`/`rangeKey` to `DynamoDb_Table.make`. Update to use `keySchema`.

5. **`Util_DynamoDbStream.res`** — `makeTable` passes `~rangeKey` to `Util_DynamoDb.makeTable`. Same update.

6. **`Util_DynamoDb.toResolvedTableOutput`** — reads `table.hashKey`/`table.rangeKey` from the output type. Keep reading from outputs (still available) unless provider drops them.

### Adapter layer (`reventless/reventless-aws/src/adapter/`)

7. **`DcbEventLogStorage_DynamoDb.res`** — creates table with `~rangeKey="position"` and GSI with `hashKey`/`rangeKey`.

8. **`EventLogStorage_DynamoDb.res` / `EventLogStorage_DynamoDbStream.res`** — create tables with `~rangeKey="sequenceNr"`.

9. **`QueryDbStorage_DynamoDb.res` / `QueryDbStorage_DynamoDbStream.res`** — create tables with optional `~rangeKey`.

### Runtime layer (no changes expected)

10. **`Util_DynamoDb_Runtime.res`** — uses `table.hashKey`/`table.rangeKey` at Lambda runtime for DynamoDB operations. These are our own record fields passed to the runtime, not Pulumi inputs — no change needed.

11. **`QueryDbStorage_DynamoDb_Runtime.res`** — same, reads `table.hashKey`. No change.

## Steps

### Step 1: Update `DynamoDb_Table.res` bindings

- Add `keySchema` type and field to `args`
- Remove `hashKey`/`rangeKey` from `args` (or keep as deprecated aliases if provider still accepts both)
- Keep `hashKey`/`rangeKey` on the output type `t` (provider still returns them)
- Check GSI/LSI types for same deprecation

### Step 2: Update `Util_DynamoDb.makeTable`

- Convert `~hashKey`/`~rangeKey` parameters to `keySchema` array in the args
- Helper: `let keySchema = [{attributeName: "id", keyType: "HASH"}] ++ rangeKey->Option.mapOr([], rk => [{attributeName: rk, keyType: "RANGE"}])`

### Step 3: Update `Util_DynamoDbStream.makeTable`

- Same pattern as Step 2

### Step 4: Build and verify zero warnings

- `npm run build`
- Deploy platform and plugin stacks, verify no `hash_key is deprecated` warnings

## Risk

- **Low risk**: This is a field rename in Pulumi inputs. The DynamoDB tables themselves don't change — same hash/range key attributes, just declared differently.
- **Pulumi state**: Pulumi should treat the keySchema-based declaration as equivalent to hashKey/rangeKey. No table replacement expected. Verify with `pulumi preview` before applying.
- **GSI/LSI**: Need to check if the Pulumi provider also deprecated `hashKey`/`rangeKey` on secondary index types, or only on the table itself.
