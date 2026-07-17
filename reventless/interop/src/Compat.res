// ── Protocol compatibility ─────────────────────────────────────────────────────

// Error variants produced when an extension's declared protocol versions are
// incompatible with the host extension point's declared versions.
type protocolError =
  | IncompatibleCommandSchema({
      extensionPointName: string,
      hostVersion: string,
      extensionVersion: string,
    })
  | IncompatibleEventSchema({
      extensionPointName: string,
      hostVersion: string,
      extensionVersion: string,
    })
  // A version string that isn't valid SemVer at all — distinct from a
  // well-formed but incompatible one, so callers can tell "you shipped garbage"
  // from "your version is too old".
  | MalformedVersion({
      extensionPointName: string,
      version: string,
    })

// Parse a SemVer string "MAJOR.MINOR.PATCH" into integer components, ignoring any
// prerelease (`-alpha.1`) or build (`+sha`) suffix. Returns None only when the
// MAJOR.MINOR.PATCH core is itself malformed. (This codebase lives on `-alpha`
// versions, so stripping the prerelease is essential — otherwise every version
// parsed as None and was reported incompatible.)
let parseSemVer = (v: string): option<(int, int, int)> => {
  let core = v->String.split("+")->Array.get(0)->Option.getOr(v)
  let core = core->String.split("-")->Array.get(0)->Option.getOr(core)
  let parts = core->String.split(".")
  if parts->Array.length != 3 {
    None
  } else {
    switch (
      parts->Array.getUnsafe(0)->Int.fromString,
      parts->Array.getUnsafe(1)->Int.fromString,
      parts->Array.getUnsafe(2)->Int.fromString,
    ) {
    | (Some(ma), Some(mi), Some(pa)) => Some((ma, mi, pa))
    | _ => None
    }
  }
}

// Validate that a single extension protocol declaration is compatible with the host's
// declared schema versions. Returns an array of errors (empty = compatible).
//
// Compatibility rule:
//   MAJOR must match exactly.
//   Host MINOR must be >= extension MINOR.
//   If MINOR is equal, host PATCH must be >= extension PATCH.
//
// Malformed SemVer strings are treated as incompatible.
let validateProtocol = (
  ~host: ExtensionPointProtocol.schemaVersions,
  ~extensionPointName: string,
  ~commandVersion: string,
  ~eventVersion: string,
): array<protocolError> => {
  let checkVersion = (hostV, extV, makeError) =>
    switch (parseSemVer(hostV), parseSemVer(extV)) {
    | (Some((hMa, hMi, hPa)), Some((eMa, eMi, ePa))) =>
      if hMa != eMa {
        [makeError()]
      } else if hMi < eMi {
        [makeError()]
      } else if hMi == eMi && hPa < ePa {
        [makeError()]
      } else {
        []
      }
    // Report the actually-malformed string rather than a bogus incompatibility.
    | (None, _) => [MalformedVersion({extensionPointName, version: hostV})]
    | (_, None) => [MalformedVersion({extensionPointName, version: extV})]
    }

  Array.concat(
    checkVersion(
      host.commandVersion,
      commandVersion,
      () =>
        IncompatibleCommandSchema({
          extensionPointName,
          hostVersion: host.commandVersion,
          extensionVersion: commandVersion,
        }),
    ),
    checkVersion(
      host.eventVersion,
      eventVersion,
      () =>
        IncompatibleEventSchema({
          extensionPointName,
          hostVersion: host.eventVersion,
          extensionVersion: eventVersion,
        }),
    ),
  )
}

// ── Field-manifest compatibility ───────────────────────────────────────────────

// Compatibility error variants produced by field-manifest validation and JSON decoding.
// Used by Query.res when querying remote stacks and by consumers inspecting queryAll results.
type error =
  | MissingRequiredField({stackName: string, outputName: string, field: string})
  | MetaMissing({stackName: string})
  | DecodeFailed({stackName: string, reason: string})

// Validate that all `requiredFields` are listed in the published field manifest for
// `outputName`, then call `fromJson` to decode the raw stack export value.
//
// `stackName` is used only for error context — it should be the Pulumi stack name
// (e.g. "org/plugin-name/prod") that published the export being validated.
let validateAndProject = (
  ~stackName: string,
  ~meta: ExportMeta.t,
  ~outputName: string,
  ~rawJson: JSON.t,
  ~requiredFields: array<string>,
  ~fromJson: JSON.t => result<'t, string>,
): result<'t, error> => {
  module SSet = Belt.Set.String
  let available =
    meta.fields
    ->Dict.get(outputName)
    ->Option.getOr([])
    ->SSet.fromArray
  switch requiredFields->Array.find(f => !SSet.has(available, f)) {
  | Some(missing) =>
    Error(MissingRequiredField({stackName, outputName, field: missing}))
  | None =>
    fromJson(rawJson)->Result.mapError(reason => DecodeFailed({stackName, reason}))
  }
}
