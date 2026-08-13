// Shared runtime helpers for the two admin-query resolver Lambdas
// (Platform_UIFragments, Platform_ComponentDefinitions). Both scan a read-model
// table and collapse the rows to the highest version per bare plugin name.
//
// Runtime-pure and self-contained: bare `@aws-sdk/*` specifiers (resolved from
// the managed runtime via the ESM resolve-hook), no `PulumiAws` — so it ships
// inside an EntryPoint code archive with no serialized closure and no Pulumi in
// the cold-start graph. Extracted from the former inline JS handler strings,
// which duplicated the version comparator verbatim across both files.

// ── @aws-sdk DynamoDB DocumentClient (bare specifiers) ──────────────────────

type ddbClient
type docClient
@module("@aws-sdk/client-dynamodb") @new external makeDdbClient: unit => ddbClient = "DynamoDBClient"
@module("@aws-sdk/lib-dynamodb") @scope("DynamoDBDocumentClient")
external docFrom: ddbClient => docClient = "from"

type scanInput = {
  @as("TableName") tableName: string,
  @as("Limit") limit?: int,
  @as("ExclusiveStartKey") exclusiveStartKey?: JSON.t,
  @as("FilterExpression") filterExpression?: string,
  @as("ExpressionAttributeNames") expressionAttributeNames?: dict<string>,
  @as("ExpressionAttributeValues") expressionAttributeValues?: dict<JSON.t>,
}
type scanCommand
@module("@aws-sdk/lib-dynamodb") @new external makeScanCommand: scanInput => scanCommand = "ScanCommand"
type scanOutput = {
  @as("Items") items?: array<dict<JSON.t>>,
  @as("LastEvaluatedKey") lastEvaluatedKey?: JSON.t,
}
@send external send: (docClient, scanCommand) => promise<scanOutput> = "send"

// One document client per container (cold start).
let doc = makeDdbClient()->docFrom

// Drain every page of a table scan (1000/page), following LastEvaluatedKey.
let scanAll = async (
  ~tableName: string,
  ~filterExpression: option<string>=?,
  ~expressionAttributeNames: option<dict<string>>=?,
  ~expressionAttributeValues: option<dict<JSON.t>>=?,
): array<dict<JSON.t>> => {
  let items = []
  let startKey = ref(None)
  let more = ref(true)
  while more.contents {
    let out =
      await doc->send(
        makeScanCommand({
          tableName,
          limit: 1000,
          exclusiveStartKey: ?startKey.contents,
          filterExpression: ?filterExpression,
          expressionAttributeNames: ?expressionAttributeNames,
          expressionAttributeValues: ?expressionAttributeValues,
        }),
      )
    out.items->Option.forEach(is => is->Array.forEach(i => items->Array.push(i)))
    switch out.lastEvaluatedKey {
    | Some(k) => startKey := Some(k)
    | None => more := false
    }
  }
  items
}

// ── Version comparison ──────────────────────────────────────────────────────

// `Number(...)` binding so the numeric-segment comparison is byte-identical to
// the former JS `cmpVer` (empty string is guarded separately, exactly as before).
@val external jsNumber: string => float = "Number"

// Compare two version strings (`-`/`+` normalised to `.`, then segment-wise:
// numeric segments compared as numbers, others lexically). Mirrors the platform
// invariant "one version per plugin at a time" ordering. Returns 1/-1/0.
let compareVersions = (a: string, b: string): int => {
  let norm = s => s->String.replaceRegExp(%re("/[-+]/g"), ".")->String.split(".")
  let pa = norm(a)
  let pb = norm(b)
  let len = Math.Int.max(pa->Array.length, pb->Array.length)
  let res = ref(0)
  let i = ref(0)
  while res.contents == 0 && i.contents < len {
    let sa = pa->Array.get(i.contents)->Option.getOr("")
    let sb = pb->Array.get(i.contents)->Option.getOr("")
    let na = jsNumber(sa)
    let nb = jsNumber(sb)
    let bothNum = sa != "" && sb != "" && !Float.isNaN(na) && !Float.isNaN(nb)
    if bothNum {
      if na > nb {
        res := 1
      } else if na < nb {
        res := -1
      }
    } else if sa > sb {
      res := 1
    } else if sa < sb {
      res := -1
    }
    i := i.contents + 1
  }
  res.contents
}

// Collapse scanned rows to the highest-version entry per bare plugin name.
// `nameVersionOf` reads the row's `name@version` string; `toEntry` builds the
// output entry for a surviving row (returning None drops a malformed row). The
// name/version split mirrors ReventlessCore.Plugin.name / compareVersions.
// Generic in what an entry is: the GraphQL fields collapse to encoded JSON, the
// bake collapses to the decoded structure it curates. One version-collapse rule
// either way — a second copy would be a second chance to disagree about which
// version of a plugin is the deployed one.
let latestByName = (
  items: array<dict<JSON.t>>,
  ~nameVersionOf: dict<JSON.t> => option<string>,
  ~toEntry: (dict<JSON.t>, ~name: string) => option<'entry>,
): array<'entry> => {
  // bare plugin name -> (version, entry); highest version wins.
  let latest: dict<(string, 'entry)> = Dict.make()
  items->Array.forEach(item =>
    switch item->nameVersionOf {
    | None => ()
    | Some(nameVersion) =>
      let segments = nameVersion->String.split("@")
      let name = segments->Array.get(0)->Option.getOr("")
      let version = segments->Array.get(1)->Option.getOr("")
      switch item->toEntry(~name) {
      | None => ()
      | Some(entry) =>
        switch latest->Dict.get(name) {
        | Some((prevVersion, _)) if compareVersions(version, prevVersion) <= 0 => ()
        | _ => latest->Dict.set(name, (version, entry))
        }
      }
    }
  )
  latest->Dict.valuesToArray->Array.map(((_, entry)) => entry)
}
