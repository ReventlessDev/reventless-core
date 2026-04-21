/** ANSI terminal style primitives for log output.
    Kept in reventless-spec so both reventless-core (LogFormat) and
    reventless-infra (compLog in ExtensionMapping/ExtensionPointMapping)
    can share the same styling helpers. */

/** Wrap a string in ANSI bold escape codes. */
let bold = s => `\x1b[1m${s}\x1b[0m`
