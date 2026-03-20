type bundle = {code: Pulumi.Archive.t, sourceCodeHash: string}

@module("./Util_Bundle.mjs")
external resolveModule: string => string = "resolveModule"

@module("./Util_Bundle.mjs")
external bundleHandler: (~entryPoint: string, ~exportName: string) => bundle = "bundleHandler"

@module("./Util_Bundle.mjs")
external bundleEntryPoint: string => bundle = "bundleEntryPoint"
