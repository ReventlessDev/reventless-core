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
// This type combination doesn't work correctly

// BAD: ignore on Output
output->ignore
// Outputs must be consumed or assigned

// BAD: non-piped apply
Pulumi.Output.apply(output, fn)
// Use piped version: output->Pulumi.Output.apply(fn)
```

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
