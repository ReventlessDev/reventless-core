/** Bindings for [`node:module`](https://nodejs.org/api/module.html).

    `createRequire` is how an ESM module gets at CommonJS resolution, which is
    what `require.resolve` is wanted for here — locating a dependency's on-disk
    path without importing it. */

type require

@module("node:module")
external createRequire: string => require = "createRequire"

@send external requireResolve: (require, string) => string = "resolve"
