/** Bindings for [`import.meta`](https://nodejs.org/api/esm.html#importmeta).

    `@val` externals are inlined at the use site rather than re-exported by this
    module, so each of these resolves to the location of the module that *reads*
    it — which is the only reason binding a per-module value from a shared
    package is sound. Reading one through a wrapper function defined here would
    return this file's location instead, so there are no helpers below.

    `dirname` and `filename` are Node's own additions and are defined only for
    `file:` URLs; a bundler that rewrites modules to CommonJS drops them. `url`
    is the portable form and the one to reach for when either could apply. */

@val @scope(("import", "meta"))
external url: string = "url"

@val @scope(("import", "meta"))
external dirname: string = "dirname"

@val @scope(("import", "meta"))
external filename: string = "filename"
