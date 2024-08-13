---
title: ReScript Syntax
date: 2022-11-02
draft: true
---

Some most commonly used ReScript features and syntax shall be highlighted here. See [https://rescript-lang.org/](https://rescript-lang.org/) for the complete documtation of ReScript.

## Types

### Commonly knwon types

`string`, `int`, `float`, `bool` are commonly known types, which are also present in ReScript.

These can be used either directly or aliased to a different type name.

```rescript
type name = string
type age = int
type hasBlueEyes = bool
```

`unit` type has a single value, `()`. This is similar to `void` used in other languages.

[See ReScript documentation for more information primitive types.](https://rescript-lang.org/docs/manual/latest/primitive-types)

### Record Type

Record types are similar to simple common objects. They provide a way to group properties and label them with meaningfull keys.

```rescript
type person = { name: string, age: int }

let person = {name: "John", age: 42}
```

Acess a single property by using the variable name (of the record value) and append a dot (`.`) followed by the property name.

```rescript
let name = person.name
```

[See ReScript documentation for more information on Record types.](https://rescript-lang.org/docs/manual/latest/record)

### Variant Type

Variants define a type which represents `xor` of several predefined cases. Each case can have it's own (different) payload.

```rescript
type person = { name: string, age: int } // record type as seen above

type command =
  | Rename(person)
  | IncreaseAge(int)
```

[See ReScript documentation for more information on Variant types.](https://rescript-lang.org/docs/manual/latest/variant)

## Inline Records

If a record type is only used as the payload of a single case in a variant type definition, the record may be inlined.

```rescript
type command =
  | Introduce({ name: string, age: int })
  | Rename(string)
  | IncreaseAge(int)
  | Forget
```

## Option

The option type is used to explicitly represent a value, which may be present (or not).

```rescript
type person = { name: string, title: option(string) }
let alice = {name: "Alice",  title: Some("Dr.")}
let bob = {name: "Bob", title: None}
```

## Control Structures

### Function

Functions name a block of executable code and it's parameters.

```rescript
let praise = (name) => name ++ " is a genius!"
```

### Switch

Switch statements are similar to `if - else if - else`, but more readable and with super powers (pattern matching / destructuring).

```rescript
let command = IncreaseAge(1);

let increasedAgeAmount = switch(command) {
  | Introduce(_)
  | Rename(_)
  | Forget => 0 // note: since Rename and Forget use the same number of variables in this case (0), they can be defined together with a single outcome
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

Switch statements can be used for different type than variants as well.

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

Given a "complex" data structure (like a record or a variant) you can destructure it.

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
    ++ person.age->Belt.Int.toString
    ++ " years old."

// in this specific case, age could also be destructured
// note you are not limited to destructuring a single value!
let sayHiAdvanced = ({name: personName, age}) =>
    "hello "
    ++ personName
    ++ ", you are "
    ++ age->Belt.Int.toString
    ++ " years old."
```

## Modules

TODO

### Module Types

TODO

### First Class Modules

TODO

### Functors (higher order functions)

[Official Rescript documentation on functors.](https://rescript-lang.org/docs/manual/latest/module#module-functions-functors)

TODO
