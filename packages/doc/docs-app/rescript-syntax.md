---
title: ReScript Syntax
date: 2022-11-02
draft: false
---

Some most commonly used ReScript features and syntax shall be highlighted here. See [https://rescript-lang.org/](https://rescript-lang.org/) for the complete documtation of ReScript.

## Types

### Commonly known types

[`string`](https://rescript-lang.org/docs/manual/latest/primitive-types#string), [`int`](https://rescript-lang.org/docs/manual/latest/primitive-types#integers), [`float`](https://rescript-lang.org/docs/manual/latest/primitive-types#floats), [`bool`](https://rescript-lang.org/docs/manual/latest/primitive-types#boolean) are commonly known [types](https://rescript-lang.org/docs/manual/latest/type), which are also present in ReScript.

These can be used either directly or [aliased](https://rescript-lang.org/docs/manual/latest/type#type-alias) to a different type name.

```rescript
type name = string
type age = int
type hasBlueEyes = bool
```

`unit` type has a single value, `()`. This is similar to `void` used in other languages.

[See ReScript documentation for more information primitive types.](https://rescript-lang.org/docs/manual/latest/primitive-types)

### Record Type

[Record types](https://rescript-lang.org/docs/manual/latest/record) are similar to simple common objects. They provide a way to group properties and label them with meaningfull keys.

```rescript
type person = { name: string, age: int }

let person = {name: "John", age: 42}
```

Access a single property by using the variable name (of the record value) and append a dot (`.`) followed by the property name.

```rescript
let name = person.name
```

[See ReScript documentation for more information on Record types.](https://rescript-lang.org/docs/manual/latest/record)

#### scoping

If the record type you want to use is defined in another module you need to bring it's type into scope, before using it.

This can be done by opening the module or adding the scope to the first record field:

```rescript
module Example = {
  type person = { name: string, age: int}
}

let x = {
  open Example
  { name: "John", age: 42 }
}
let y = { Example.name: "Eric", age: 13 }
```

### Variant Type

[Variants](https://rescript-lang.org/docs/manual/latest/variant) define a type which represents `xor` of several predefined cases. Each case can have it's own (different) payload.

```rescript
type person = { name: string, age: int } // record type as seen above

type command =
  | Rename(person)
  | IncreaseAge(int)
```

[See ReScript documentation for more information on Variant types.](https://rescript-lang.org/docs/manual/latest/variant)

## Inline Records

If a record type is only used as the payload of a single case in a variant type definition, the [record may be inlined](https://rescript-lang.org/docs/manual/latest/variant#labeled-variant-payloads-inline-record).  
A value of the record may not be used outside of the variant.

```rescript
type command =
  | Introduce({ name: string, age: int })
  | Rename(string)
  | IncreaseAge(int)
  | Forget

let notPossible = { // record cannot be in scope
  name: "example",
  age: 42
}

let notPossibleAsWell = command => {
  switch command {
    | Introduce(r) => Some(r) // the record type would escape it's scope
    | Rename(_) => None
    | IncreaseAge(_) => None
    | Forget => None
  }
}
```

## Option

The [option](https://rescript-lang.org/docs/manual/latest/null-undefined-option) type is used to explicitly represent a value, which may be present (or not).

```rescript
type person = { name: string, title: option<string> }

let alice = {name: "Alice",  title: Some("Dr.")}
let bob = {name: "Bob", title: None}
```

## Result

The [`result`](https://rescript-lang.org/docs/manual/latest/api/core/result) type represents either success (`Ok`) or failure (`Error`). It is how Reventless commands signal outcomes.

```rescript
// Commands return result<array<event>, error>
let handle = (state, command) =>
  switch command {
  | CreateItem({name}) =>
    switch state {
    | Some(_) => Error(AlreadyExists)  // reject — entity already exists
    | None => Ok([ItemCreated({name: name})])  // accept — emit event
    }
  }
```

Pattern-match to handle both cases:

```rescript
switch await aggregate.handle(command) {
| Ok(events) => Js.log("events emitted: " ++ events->Array.length->Int.toString)
| Error(err) => Js.log("command rejected")
}
```

## Control Structures

### Function

[Functions](https://rescript-lang.org/docs/manual/latest/function) name a block of executable code and it's parameters.

```rescript
let hello = (name) => "Hello " ++ name ++ "!"
let helloGuest = hello("Guest") // "Hello Guest!"
```

### Pipe Operator `->`

The pipe operator `->` passes the left-hand value as the **first argument** of the right-hand function. It chains transformations without nested calls or intermediate variables.

```rescript
// Without pipe
let result = Array.map(events, encodeEvent)

// With pipe — reads left to right
let result = events->Array.map(encodeEvent)

// Chain multiple operations
let ids =
  events
  ->Array.filter(e => e.version > 0)
  ->Array.map(e => e.id)
```

Reventless uses `->` everywhere — reading code fluently requires recognizing this pattern.

### Switch

[Switch](https://rescript-lang.org/docs/manual/latest/pattern-matching-destructuring#switch-based-on-shape-of-data) statements are similar to `if - else if - else`, but more readable and with super powers (pattern matching / [destructuring](#destructuring).

```rescript
let command = IncreaseAge(1);

let increasedAgeAmount = switch(command) {
  | Introduce(_)
  | Rename(_)
  | Forget => 0 // note: since Rename and Forget match on the same number of variables in this case (none), they can be defined together with a single outcome
  | IncreaseAge(amount) => amount
}

let newName = switch(command) {
  | Introduce({name: newName})
  | Rename(newName) =>
      Some(newName)
  | Forget
  | IncreaseAge =>
      None
}
```

Switch statements can be used for different types than variants as well.

```rescript
let name = "Charlie"

let nameIsAlice = switch(name) {
  | "Alice" => true
  | _ => false // note: _ means anything else
```

### `_` placeholder in case statements

`_` can be used as a case statement with the meaning of "anything else" not matched previously.

If you have a limited (defined) set of possible values the compiler will check if all possible values are presented in the switch statement. The moment you introduce `_`, the compiler will acknowledge that every case is handled. But this also takes the compiler's power away of helping you in future refactorings or code updates.

**This should be used with care!**
**Whenever possible (and feasable) enumerate all possible values explicitly!**

## Utilities

### Destructuring

Given a "complex" data structure (like a record or a variant) you can [destructure](https://rescript-lang.org/docs/manual/latest/pattern-matching-destructuring#destructuring) it.

```rescript
let john = {name: "John", age: 42}
let {name: johnsName} = john
let {name: johnsName, age: johnsAge} = john
```

This can also be done in place for function arguments.

```rescript
let sayHi = ({name}) => "hello " ++ name

// which is shorter and maybe a little better readable than:
let sayHi = (person) => "hello " ++ person.name
```

If you would like to rename properties or still have access to the complete destructured value you can use the keyword `as`.

```rescript
let sayHiAdvanced = ({name: personName} as person) =>
    "hello "
    ++ personName
    ++ ", you are "
    ++ person.age->Int.toString
    ++ " years old."

// in this specific case, age could also be destructured
// note you are not limited to destructuring a single value!
let sayHiAdvanced = ({name: personName, age}) =>
    "hello "
    ++ personName
    ++ ", you are "
    ++ age->Int.toString
    ++ " years old."
```

## Arrays

Arrays are the primary collection type in Reventless. Commands return `array<event>`, and many APIs accept or return arrays.

```rescript
// Array literal
let events: array<event> = [ItemCreated({name: "Widget"}), ItemTagged({tag: "new"})]

// Empty array — "no events" from a command that makes no change
let noChange: array<event> = []

// Common operations (from RescriptCore)
let count = events->Array.length
let first = events->Array.getUnsafe(0)  // unsafe — only when index is known valid
let mapped = events->Array.map(encodeEvent)
let filtered = events->Array.filter(e => e != IgnoredEvent)
```

## `open` Statement

`open` brings all values and types from a module into the current scope, avoiding repeated module prefixes.

```rescript
// Without open
let result = Reventless.EventLog.make(~name="orders")

// With open
open Reventless.EventLog
let result = make(~name="orders")
```

Files in Reventless often begin with `open RescriptCore` (from `-open RescriptCore` in `rescript.json`) which makes standard library functions (`Array`, `String`, `Int`, etc.) available without prefix.

:::caution Warning 44: open shadows
If two opened modules export the same name, the compiler emits warning 44. Fix by removing the redundant `open`, qualifying the ambiguous name, or adding `@@warning("-44")` at the top of the file.
:::

## `include` Statement

`include` copies all definitions from a module (or module type) into the current one. It is used to compose module types in specs.

```rescript
// Reuse a common module type
module type MySpec = {
  include Reventless.Aggregate.Spec
  let extraConfig: string
}

// A concrete module satisfying MySpec
module MyImpl: MySpec = {
  // Must include everything from Aggregate.Spec
  let name = "MyAggregate"
  // ... plus the extra field
  let extraConfig = "value"
}
```

In Reventless, `include` appears in spec packages to build up composite module types without copying individual definitions.

## Modules

Modules are containers that group related code (types, functions, values) together. In ReScript, every `.res` file is automatically a module, with the filename becoming the module name.

```rescript
// MyModule.res
type myType = string
let myValue = "hello"

let greet = (name) => myValue ++ " " ++ name
```

You can access module contents using dot notation:

```rescript
let x = MyModule.myValue  // "hello"
let greeting = MyModule.greet("World")  // "hello World"
```

### Module Types

Module types define the signature or contract that a module must implement. They are similar to interfaces in other languages.

```rescript
// Define a module type
module type MyService = {
  let name: string
  let process: (string) => string
}

// A module implementing the type
module MyServiceImpl: MyService = {
  let name = "My Service"
  let process = (input) => input ++ " processed"
}
```

Module types are essential in Reventless for defining component specifications that can be satisfied by different implementations.

### First Class Modules

First-class modules allow you to treat modules as values that can be passed around, stored in data structures, and computed at runtime.

```rescript
// Create a module as a value
module MyModule = {
  let value = 42
}

// Pass a module to a function
let printValue = (module M: { let value: int }) => {
  Js.log(Js.Int.toString(M.value))
}

printValue(module MyModule)  // prints 42
```

In Reventless, first-class modules are used extensively for dependency injection and plugin composition:

```rescript
// A plugin that accepts module implementations
let createPlugin = (module(Aggregate: Aggregate.Spec), module(ReadModel: ReadModel.Spec)) => {
  // Use the modules...
}

// Pass concrete implementations
createPlugin(module(MyAggregate), module(MyReadModel))
```

### Functors

**Functors** (also called **module functions**) are functions that take modules as input and return modules as output. They are the cornerstone of the Reventless framework's architecture.

```rescript
// A functor definition
module MakeLogger = (Config: { let prefix: string }) => {
  let log = (message) => Js.log(Config.prefix ++ ": " ++ message)
  let error = (message) => Js.log(Config.prefix ++ " ERROR: " ++ message)
}

// Apply the functor with configuration
module InfoLogger = MakeLogger({ let prefix = "INFO" })
module DebugLogger = MakeLogger({ let prefix = "DEBUG" })

InfoLogger.log("Application started")  // "INFO: Application started"
DebugLogger.log("Application started")  // "DEBUG: Application started"
```

#### Why Functors are Essential in Reventless

Functors serve several critical purposes in the framework:

1. **Dependency Injection**
   Functors allow components to receive their dependencies as parameters. This makes the framework provider-agnostic - the same component code can work with AWS, GCP, Azure, or any other cloud provider.

   ```rescript
   // A component that works with any event log implementation
   module MakeAggregate = (EventLog: EventLog.Spec) => {
     // The aggregate uses EventLog.append() but doesn't care about the implementation
     let handle = (command) => {
       // ... process command ...
       EventLog.append(events)
     }
   }
   
   // Can use with AWS DynamoDB, in-memory, or any other implementation
   module AwsAggregate = MakeAggregate(module(AwsEventLog))
   module InMemoryAggregate = MakeAggregate(module(InMemoryEventLog))
   ```

2. **Type-Safe Configuration**
   Functors enable compile-time verification that all required configuration is provided. Missing or incorrect configuration results in clear compiler errors.

   ```rescript
   // The builder requires specific configuration
   module MakePlugin = (Config: Plugin.Config) => {
     // Compiler ensures Config has all required fields
     // Error at compile time if something is missing
   }
   ```

3. **Code Reuse**
   A single functor can generate multiple working implementations by varying the input modules. This DRYs up significant amounts of boilerplate code.

   ```rescript
   // One Aggregate functor works for all aggregates
   module OrderAggregate = Aggregate.Make({ let name = "Order" })
   module UserAggregate = Aggregate.Make({ let name = "User" })
   module ProductAggregate = Aggregate.Make({ let name = "Product" })
   ```

4. **Abstraction Over Infrastructure**
   Functors allow the framework to abstract over infrastructure details. Components define what operations they need (e.g., "append to event log") without knowing how it's implemented.

   ```rescript
   // The CommandHandler functor doesn't know about SQS, it just needs
   // something that can send messages
   module MakeCommandHandler = (Queue: CommandQueue.Spec) => {
     let send = (command) => Queue.send(command)
   }
   ```

#### Functor Syntax in Reventless

Reventless uses a consistent naming convention for functors:

```rescript
// ComponentName.res - Defines the module type (spec)
module type Spec = { ... }

// ComponentName_Builder.res - Contains the Make functor
module Make = (Spec: SomeSpec) => { ... }

// Usage: Apply the functor to get a concrete implementation
module MyComponent = MyComponent_Builder.Make(MySpec)
```

Common patterns in Reventless:
- `Make` - Primary functor for creating component instances
- Builder functors typically accept a `Spec` module with configuration and type definitions

## PPX

PPX (PreProcessor eXtensions) are compile-time code generators that transform your code. Reventless uses PPX extensions to automatically generate boilerplate code.

### Reventless PPX Annotations

Reventless uses its own PPX (`@reventlessdev/reventless-ppx`) to auto-generate boilerplate. These annotations appear in spec and behavior files.

#### `@@reventless.spec`

Place at the top of any spec file (aggregates, read models, extension points, DCB slices). Automatically injects:
- `let name` (derived from filename, strips component suffixes)

```rescript
// ItemSpec.res
@@reventless.spec

@schema type command = | CreateItem({name: string}) | DeleteItem
@schema type event = | ItemCreated({name: string}) | ItemDeleted
@schema type error = | AlreadyExists | NotFound
@schema type state = option<{name: string}>
```

For files in a `*Spec` namespace, the PPX also auto-prefixes extension point names with the plugin name.

#### `@@reventless.behavior`

Place at the top of behavior files. Automatically injects:
- `open Spec` (brings spec types into scope)
- `module Spec = Spec`

```rescript
// ItemBehavior.res  (PPX derives Spec from "Item" in filename)
@@reventless.behavior

let initialState = None

let handle = (state, command) =>
  switch (state, command) {
  | (None, CreateItem({name})) => Ok([ItemCreated({name: name})])
  | (Some(_), CreateItem(_)) => Error(AlreadyExists)
  | (None, DeleteItem) => Ok([])
  | (Some(_), DeleteItem) => Ok([ItemDeleted])
  }

let apply = (state, event) =>
  switch event {
  | ItemCreated({name}) => Some({name: name})
  | ItemDeleted => None
  }
```

#### `@@reventless.mappings`

File-level attribute on `<Plural>_Projections.res` (multi-source ReadModel projections) and `<Entity>_Mappings.res` (Aggregate event-mapping siblings). The PPX infers the domain from the folder (`ReadModel/` → `Reventless.Projection`, `Aggregate/` → `Reventless.EventMapping`), injects the `Mappings.Make` wrapper and the `module type Mapping`, scans inner DCB Source modules, and lets the user write only the per-source `Mapping.Make` modules and the `let mappings` array:

```rescript
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  Products,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) => Set(id, {Products.name: name})
      | _ => Ignore
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

### @schema

The `@schema` PPX generates serialization/deserialization code for types:

```rescript
@schema
type command =
  | CreateItem({name: string, quantity: int})
  | DeleteItem({id: string})
```

This automatically generates:
- `commandSchema: S.t<command>` - Type-safe schema for serialization
- JSON encoding/decoding functions
- Validation logic

### @s.matches

Used in DCB (Dynamic Consistency Boundary) contexts to mark fields as queryable tags. In most cases you **do not need to write this annotation manually** — the Reventless PPX auto-injects it.

#### PPX Auto-Injection (Normal Case)

Files inside any `*Slice/` folder (StateChangeSlice, StateViewSlice, AutomationSlice, etc.) automatically get DCB tags applied by `@@reventless.spec`. Fields named `*Id: string` and `*Ids: array<string>` are tagged without any manual annotation:

```rescript
// ItemStateChangeSlice/ItemSpec.res
@@reventless.spec

@schema type command = | CreateItem({itemId: string, name: string})
// ↑ PPX auto-injects @s.matches(DcbTag.string) on itemId
```

#### Manual Use (Edge Cases)

Outside slice folders, or when field names don't follow the `*Id`/`*Ids` convention, annotate explicitly. **The annotation must go on the type expression (after the colon), not on the field name:**

```rescript
// Correct — annotation on the type expression
type event =
  | ItemCreated({itemId: @s.matches(DcbTag.string) string, name: string})

// Wrong — annotation on the field name (silently ignored by ppx)
type event =
  | ItemCreated({@s.matches(DcbTag.string) itemId: string, name: string})
```

Fine-grained control is available via field-level annotations: `@partitionTag` (marks the partition key when multiple `*Id` fields exist), `@compositePartitionTag` (builds a partition key from multiple fields joined in declaration order), `@noTag` (suppresses auto-tagging), `@dcbTag` (tags a field that doesn't follow `*Id` naming).

See [DCB Slices](./dcb-slices.md) for how DCB tags are used in practice.
