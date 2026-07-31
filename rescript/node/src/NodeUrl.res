/** Bindings for [`node:url`](https://nodejs.org/api/url.html).

    Only the two path/URL converters — the `URL` class itself is a WHATWG global
    rather than a `node:` import, so it belongs to `rescript-web`, not here. */

@module("node:url")
external fileURLToPath: string => string = "fileURLToPath"

@module("node:url")
external pathToFileURL: string => {"href": string} = "pathToFileURL"
