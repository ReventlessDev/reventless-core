---
title: Extension Point
date: 2021-11-22
draft: false
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
[@decco]
type command =
    | InformExtensionPoint(bool)
    | TellExtensionPointSomethingElse(someRecord); // or unit if not used

[@decco]
type event =
    | SomethingHappened(bool, string)
    | SomethingElseHappened(int);

[@decco]
type callCommand = 
    | CallSomeSideEffect(int); // or unit if not used

```

## command


## event


## callCommand
These label side-effects, which can occur in an `ExtensionPoint` or `Extension` using this `ExtensionPointSpec`. The handling of such side-effects gets implemented in the `ExtensionPointMapping`s and `ExtensionMapping`s.