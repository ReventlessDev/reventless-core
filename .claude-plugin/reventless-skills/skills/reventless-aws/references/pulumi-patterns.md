# Pulumi Patterns

## Output.t Wrapping

All infrastructure values are wrapped in `Pulumi.Output.t<'a>` during deploy-time:

```rescript
// DynamoDB table name is an Output — resolved after creation
let tableName: Pulumi.Output.t<string> = table.name

// Transform inside Output
let upperName = tableName->Pulumi.Output.apply(name => String.toUpperCase(name))

// Combine multiple outputs
let combined = Pulumi.Output.all2(tableArn, queueUrl)->Pulumi.Output.apply(((arn, url)) => {
  {tableArn: arn, queueUrl: url}
})
```

## Component Resources

Each Reventless component extends `Pulumi.ComponentResource`:

```rescript
// Framework creates component resources with parent-child relationships
let eventLog = Pulumi.ComponentResource.make(
  "reventless:EventLog",
  name,
  ~opts=Pulumi.CustomResourceOptions.make(~parent=plugin),
)
```

Resources created as children:
- DynamoDB tables (EventLog, QueryDb)
- SQS queues (CommandTopic)
- SNS topics (EventTopic)
- Lambda functions (handlers)
- IAM roles and policies

## Code Smells

**Avoid these patterns:**

```rescript
// BAD: option wrapping Output
let x: option<Pulumi.Output.t<string>> = Some(output)
// This type combination doesn't work correctly (see below)

// BAD: ignore on Output
output->ignore
// Outputs must be consumed or assigned

// BAD: non-piped apply
Pulumi.Output.apply(output, fn)
// Use piped version: output->Pulumi.Output.apply(fn)
```

### Why `option<Pulumi.Output.t>` Breaks

Pulumi Output objects use **property lifting** — accessing any property on an Output returns a new Output (a truthy object), even non-existent properties. ReScript's runtime option encoding (`Primitive_option.some`) checks `x.BS_PRIVATE_NESTED_SOME_NONE !== undefined` to detect nested options. On a Pulumi Output, this property returns a truthy Output instead of `undefined`, so `some(output)` misidentifies it as a nested option and produces `{BS_PRIVATE_NESTED_SOME_NONE: 0}` instead of the actual Output value.

This breaks `Option.map`, `Option.flatMap`, pattern matching via `valFromOption`, and Pulumi exports (which serialize the broken encoding instead of the resolved string).

```rescript
// BAD — Option.map calls Primitive_option.some on the return value
let tableName = resources->Array.get(0)->Option.map(r => r.name)
// Result: {BS_PRIVATE_NESTED_SOME_NONE: 0} instead of Output.t<string>

// GOOD — explicit switch avoids Primitive_option.some wrapping
let tableName = switch resources->Array.get(0) {
| Some(r) => Some(r.name)
| None => None
}
```

This applies anywhere `option<Pulumi.Output.t<'a>>` is produced — optional function parameters, record fields, and return values. When extracting an `Output.t` field from an optional container, always use an explicit `switch`.

## ReScript Pulumi Bindings

- `@reventlessdev/rescript-pulumi-pulumi` — core Pulumi bindings
- `@reventlessdev/rescript-pulumi-aws` — AWS resource bindings

## Stack References

For cross-stack access:

```rescript
let stackRef = Pulumi.StackReference.make("org/project/stack")
let output: Pulumi.Output.t<option<JSON.t>> = stackRef->getOutput("key")
```

Annotate as `Output.t<option<JSON.t>>` for sury parsing compatibility.
