/** Bindings for [`node:path`](https://nodejs.org/api/path.html).

    `join` and `resolve` are variadic, which is a strict superset of the
    two-argument form they replace, so no call site loses expressiveness. A
    two-argument `join` and a variadic one are not duplicates of each other —
    they are different functions with the same name, and which one a call site
    got used to depend on which inline binding block it happened to sit near. */

@module("node:path") @variadic
external join: array<string> => string = "join"

@module("node:path") @variadic
external resolve: array<string> => string = "resolve"

@module("node:path")
external dirname: string => string = "dirname"

@module("node:path")
external basename: string => string = "basename"

@module("node:path")
external relative: (string, string) => string = "relative"

@module("node:path") @val
external sep: string = "sep"
