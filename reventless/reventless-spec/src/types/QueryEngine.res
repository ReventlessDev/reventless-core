/**
A typed query value used as a filter operand.

Wraps the three primitive types supported by the query engine so that
filter comparisons are type-safe without requiring a raw JSON representation.
*/
type value =
  | String(string)
  | Int(int)
  | Bool(bool)

/**
Filter operations for read model queries.

`Filter.config` is a triple `(fieldName, comparator, value)` applied on top of
the primary key lookup to narrow the result set.

@example
```rescript
// Only return categories where archived = false
let activeFilter: QueryEngine.Filter.config = ("archived", Equal, Bool(false))
```
*/
module Filter = {
  /** Comparison operators available for field-level filters. */
  type comparator =
    | Equal
    | Unequal
    | LessOrEqual
    | Less
    | GreaterOrEqual
    | Greater
    /** Field must exist (have a value). */
    | Exists
    /** Field must not exist. */
    | NotExists
    /** String / set membership: field contains the given substring or element. */
    | Contains
    | NotContains
    | BeginsWith

  /** A filter specification: `(fieldName, comparator, value)`. */
  type config = (string, comparator, value)
}

/**
Sub-ID filter operations for composite-key read model queries.

`SubId.config` narrows results within a partition already selected by the primary ID.

@example
```rescript
// Only return rows where subId begins with "cat-"
let categoryFilter: QueryEngine.SubId.config = ("categoryId", BeginsWith, String("cat-"))
```
*/
module SubId = {
  /** Comparison operators available for sub-ID range conditions. */
  type comparator =
    | Equal
    | Unequal
    | LessOrEqual
    | Less
    | GreaterOrEqual
    | Greater
    | BeginsWith

  /** A sub-ID filter specification: `(subIdField, comparator, value)`. */
  type config = (string, comparator, value)
}

/**
Fetches rows from a read model by primary key, with optional sub-ID range and
additional attribute filters.

@example
```rescript
let rows = await queryEngine.query(
  ~readModelName="Categories",
  ~id=String("cat-1"),
  ~filterConfigs=[("archived", Filter.Equal, Bool(false))],
)
```
*/
type query = (
  ~readModelName: string,
  ~key: string=?,
  ~id: value,
  ~subIdConfig: SubId.config=?,
  ~filterConfigs: array<Filter.config>=?,
  ~ascending: bool=?,
  ~limit: int=?,
) => promise<array<JSON.t>>

/**
Scans an entire read model table with attribute filters (no primary key).

Use only when no primary key is available; scans are more expensive than queries.

@example
```rescript
let allActive = await queryEngine.scan(
  ~readModelName="Categories",
  ~filterConfigs=[("archived", Filter.Equal, Bool(false))],
  ~limit=100,
)
```
*/
type scan = (
  ~readModelName: string,
  ~filterConfigs: array<Filter.config>,
  ~limit: int,
) => promise<array<JSON.t>>

/**
Runtime query engine injected into task handlers, side effects, and extension point mappings.

Provides provider-agnostic read access to all read models in the plugin.
*/
type operations = {
  scan: scan,
  query: query,
}
