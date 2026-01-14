---
title: Extension Point
date: 2021-11-22
---

# Extension Point

> **TODO**: complete this documentation

An `ExtensionPoint` is specified like this:
```re
let name = "<Plugin>.<ExtensionPointName>";

type someRecord = {
    specialMeaning: int,
    otherValue: bool,
    someDescription: string
};
@schema
type command =
    | InformExtensionPoint(bool)
    | TellExtensionPointSomethingElse(someRecord); // or unit if not used

@schema
type event =
    | SomethingHappened(bool, string)
    | SomethingElseHappened(int);

@schema
type callCommand =
    | CallSomeSideEffect(int); // or unit if not used

```

## command


## event


## callCommand
These label side-effects, which can occur in an `ExtensionPoint` or `Extension` using this `ExtensionPointSpec`. The handling of such side-effects gets implemented in the `ExtensionPointMapping`s and `ExtensionMapping`s.