@val external describe: (string, unit => unit) => unit = "describe"
@val external test: (string, unit => unit) => unit = "test"
@val external testAsync: (string, unit => promise<unit>) => unit = "test"

type expectResult

@val external expect: 'a => expectResult = "expect"
@send external toBe: (expectResult, 'a) => unit = "toBe"
@send external toEqual: (expectResult, 'a) => unit = "toEqual"
@send external toContain: (expectResult, string) => unit = "toContain"
@get external not_: expectResult => expectResult = "not"
@send external toHaveLength: (expectResult, int) => unit = "toHaveLength"
@send external toBeGreaterThan: (expectResult, int) => unit = "toBeGreaterThan"
