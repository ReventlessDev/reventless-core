@module("./Util_Bundle.mjs")
external resolveModule: string => string = "resolveModule"

@module("./Util_Bundle.mjs")
external bundleHandler: (~entryPoint: string, ~exportName: string) => Pulumi.Archive.t =
  "bundleHandler"

@module("./Util_Bundle.mjs")
external bundleEntryPoint: string => Pulumi.Archive.t = "bundleEntryPoint"
