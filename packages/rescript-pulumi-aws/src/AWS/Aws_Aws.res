type getRegionArgs = {endpoint?: string, name?: string}

type getRegionResult = {description: string, endpoint: string, id: string, name: string}

@module("@pulumi/aws")
external getRegion: (
  ~args: getRegionArgs=?,
  ~opts: Pulumi.InvokeOptions.t=?,
) => Js.Promise.t<getRegionResult> = "getRegion"

@module("@pulumi/aws")
external getRegionSync: (
  ~args: getRegionArgs=?,
  ~opts: Pulumi.InvokeOptions.t=?,
) => getRegionResult = "getRegion"

let getRegionSync: (~args: getRegionArgs=?, ~opts: Pulumi.InvokeOptions.t=?) => getRegionResult = (
  ~args=?,
  ~opts=?,
) => {
  let (parent, provider, version) = switch opts {
  | Some(opts) => (opts.parent, opts.provider, opts.version)
  | None => (None, None, None)
  }

  let opts = {?Pulumi.InvokeOptions.parent, ?provider, ?version, async: false}

  getRegionSync(~args?, ~opts)
}
