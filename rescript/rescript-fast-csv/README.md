[![npm version](https://img.shields.io/npm/v/@reventlessdev/rescript-fast-csv.svg?label=version)](https://www.npmjs.com/package/@reventlessdev/rescript-fast-csv)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Changelog](https://img.shields.io/badge/📋-Changelog-blue)](./CHANGELOG.md)

# `rescript-fast-csv`

ReScript bindings for [fast-csv](https://github.com/C2FO/fast-csv), a fast and flexible CSV parsing library for Node.js.

## Installation
- Add `rescript-fast-csv` to your dependencies in `package.json`.
- Add `rescript-fast-csv` to your dependencies in `rescript.json`.
- For general information see this monorepo's [readme](../../README.md)

## Core API

### Parsing Functions

#### `parseFile`
Parse a CSV file from the filesystem.

```rescript
parseFile(~path: string, ~options: Options.t=?) => csvParserStream
```

**Example:**
```rescript
FastCSV.parseFile(
  ~path="data.csv",
  ~options={
    headers: Bool(true),
    delimiter: ","
  }
)
```

#### `parseStream`
Parse a CSV from a Node.js readable stream.

```rescript
parseStream(~stream: NodeStreams.Readable.t, ~options: Options.t=?) => csvParserStream
```

### Parser Options

Configure the CSV parser behavior using the `Options.t` type:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `objectMode` | `bool` | `true` | Parse rows as objects with named fields |
| `delimiter` | `string` | `","` | Character used to separate columns |
| `quote` | `Js.Nullable.t<string>` | `'"'` | Character used to quote fields |
| `escape` | `string` | `'"'` | Character used to escape quotes |
| `headers` | `Bool(bool)` \| `String(array<string>)` | `false` | Use first row as headers or provide custom headers |
| `renameHeaders` | `bool` | `false` | Allow headers to be renamed |
| `ignoreEmpty` | `bool` | `false` | Skip empty rows |
| `comment` | `string` | `null` | Character that starts comment lines (skipped) |
| `discardUnmappedColumns` | `bool` | `false` | Discard columns not in headers |
| `strictColumnHandling` | `bool` | `false` | Throw error if row column count differs from headers |
| `trim` | `bool` | `false` | Trim whitespace from both ends of fields |
| `rtrim` | `bool` | `false` | Trim whitespace from right end of fields |
| `ltrim` | `bool` | `false` | Trim whitespace from left end of fields |

**Example:**
```rescript
{
  Options.headers: Bool(true),
  delimiter: ";",
  trim: true,
  ignoreEmpty: true,
  comment: "#"
}
```

### Event Handling Pattern

The parser uses a chainable event handler pattern. Register handlers to process rows, handle errors, and track completion:

#### `onData`
Called for each valid row parsed from the CSV.

```rescript
onData(csvParserStream, row => unit) => csvParserStream
```

**Example:**
```rescript
parseFile(~path="users.csv")
->onData(row => {
  Js.log2("Parsed row:", row)
})
```

#### `onError`
Called when the parser encounters an error.

```rescript
onError(csvParserStream, Js.Exn.t => unit) => csvParserStream
```

**Example:**
```rescript
parseFile(~path="data.csv")
->onError(err => {
  switch Js.Exn.message(err) {
  | Some(msg) => Js.log2("Parse error:", msg)
  | None => Js.log("Unknown parse error")
  }
})
```

#### `onEnd`
Called when parsing completes. Receives the total row count.

```rescript
onEnd(csvParserStream, rowCount => unit) => csvParserStream
```

**Example:**
```rescript
parseFile(~path="data.csv")
->onEnd(count => {
  Js.log(`Finished parsing ${count->Int.toString} rows`)
})
```

#### `onInvalid`
Called when a row fails validation. Only triggered if validation is registered.

```rescript
onInvalid(csvParserStream, (row, rowNumber, option<reason>) => unit) => csvParserStream
```

**Example:**
```rescript
parseFile(~path="data.csv")
->validate((row, callback) => {
  // Validation logic
  callback->toInvalid("Missing required field")
})
->onInvalid((row, rowNum, reason) => {
  switch reason {
  | Some(msg) => Js.log2(`Row ${rowNum->Int.toString} invalid:`, msg)
  | None => Js.log2(`Row ${rowNum->Int.toString} has structural errors`, row)
  }
})
```

## Complete Example: Processing User Data

```rescript
// Parse a CSV file with user data, validate entries, transform them,
// and handle errors gracefully

type user = {
  name: string,
  email: string,
  age: int,
}

let users = ref([])

FastCSV.parseFile(
  ~path="users.csv",
  ~options={
    headers: Bool(true),
    delimiter: ",",
    trim: true,
    ignoreEmpty: true,
  }
)
->FastCSV.validate((row, callback) => {
  // Check if required fields exist
  switch (Dict.get(row, "name"), Dict.get(row, "email"), Dict.get(row, "age")) {
  | (Some(_), Some(_), Some(_)) => callback->FastCSV.toValid
  | _ => callback->FastCSV.toInvalid("Missing required fields (name, email, age)")
  }
})
->FastCSV.transform((row, callback) => {
  // Transform row data
  let name = Dict.get(row, "name")->Option.getOr("")
  let email = Dict.get(row, "email")->Option.getOr("")
  let ageStr = Dict.get(row, "age")->Option.getOr("0")

  // Add transformed fields back to row
  Dict.set(row, "email", String.toLowerCase(email))
  Dict.set(row, "name", String.trim(name))

  callback->FastCSV.toValidTransformation(row)
})
->FastCSV.onData(row => {
  // Process each valid row
  switch (
    Dict.get(row, "name"),
    Dict.get(row, "email"),
    Dict.get(row, "age")->Option.flatMap(Int.fromString)
  ) {
  | (Some(name), Some(email), Some(age)) => {
      let user = {name, email, age}
      users := Array.concat(users.contents, [user])
    }
  | _ => Js.log2("Skipping invalid row:", row)
  }
})
->FastCSV.onInvalid((row, rowNumber, reason) => {
  let msg = reason->Option.getOr("Structural error")
  Js.log(`Row ${rowNumber->Int.toString}: ${msg}`)
})
->FastCSV.onError(err => {
  switch Js.Exn.message(err) {
  | Some(msg) => Js.log2("Parse error:", msg)
  | None => Js.log("Unknown parsing error occurred")
  }
})
->FastCSV.onEnd(rowCount => {
  Js.log(`Successfully parsed ${rowCount->Int.toString} rows`)
  Js.log2("Total valid users:", Array.length(users.contents))
})
```

## Validation

### Simple Validation
Use `validate` to register a validation function:

```rescript
parseFile(~path="data.csv")
->validate((row, callback) => {
  let hasRequiredField = Dict.get(row, "id")->Option.isSome
  if hasRequiredField {
    callback->toValid
  } else {
    callback->toInvalid("Missing id field")
  }
})
```

### Result-Based Validation
Use `validateResult` for cleaner validation with Result types:

```rescript
parseFile(~path="data.csv")
->validateResult(row => {
  switch Dict.get(row, "email") {
  | Some(email) if String.includes(email, "@") => Ok()
  | Some(_) => Error("Invalid email format")
  | None => Error("Email field is missing")
  }
})
```

### Multiple Validations
Use `validateMultiple` or `validateMultipleResults` to chain validations:

```rescript
let validations = [
  row => Dict.get(row, "name")->Option.isSome ? Ok() : Error("Missing name"),
  row => Dict.get(row, "age")->Option.isSome ? Ok() : Error("Missing age"),
]

parseFile(~path="data.csv")
->validateMultipleResults(validations)
```

## Transformation

Transform row data during parsing:

```rescript
parseFile(~path="data.csv")
->transform((row, callback) => {
  // Normalize field names by removing empty keys
  Dict.forEach(row, (value, key) => {
    if String.length(key) == 0 {
      Dict.delete(row, key)
    }
  })

  // Convert certain fields to uppercase
  switch Dict.get(row, "code") {
  | Some(code) => Dict.set(row, "code", String.toUpperCase(code))
  | None => ()
  }

  callback->toValidTransformation(row)
})
```

## Helper Functions

- `toValid(callback)` - Mark validation as successful
- `toInvalid(callback, reason)` - Mark validation as failed with reason
- `toError(callback, reason)` - Mark validation as error
- `toValidTransformation(callback, row)` - Complete transformation successfully
- `toErrorTransformation(callback, reason)` - Mark transformation as failed
