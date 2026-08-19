# Plan: a command argument sent as null, and the decode failure nobody can read

**Date:** 2026-08-12
**Status:** Done — implemented 2026-08-12.
**Repos:** `reventless-core` only.

## Why

Two defects, found together while probing a generated mutation. They compound:
the first makes an ordinary call fail, and the second makes the failure
unreadable.

### 1. An optional argument sent as null fails to decode

sury-ppx compiles an optional command field — `field?: t`, or `option<t>` — to
`T | undefined`. `null` is neither, so a caller who supplies one explicitly gets
a decode failure:

```
Failed parsing at ["deliveryWindow"]:
  Expected { start: string; end: string; } | undefined, received null
```

This is not specific to object-typed fields. Every optional field of every
command behaves the same way (`Expected string | undefined, received null`), and
the caller did nothing unusual — GraphQL says a nullable argument may be given
null, and the SDL this framework generates declares exactly that:

```graphql
Ordering_PlaceOrder(…, deliveryWindow: DateRangeInput): CommandResult
```

The resolvers forward their arguments verbatim
(`CommandGeneratorResolvers_GraphQL.res`, `arguments: args->Obj.magic`), and
graphql-js only puts a key in `args` when the caller actually supplied one. So
the three ways of saying "no delivery window" get three different answers:

| sent as | result |
|---|---|
| omitted | accepted |
| `null` | decode failure |
| `""` | rejected in argument coercion, before the resolver |

Only the first works, and nothing in the schema says so.

**Absent and explicitly-null are not distinguishable to a command anyway.** No
generated argument can hold a JSON null: `GraphQL_FragmentGenerator.fromSchemaType`
maps every schema type to `String`/`Float`/`Boolean`/`ID`, a generated enum, an
input object or a list — `Unknown` included, which becomes `String`. And no
command field type can *represent* an explicit null: both spellings of optional
parse `T | undefined`. So the two are the same statement, and only one of them
is accepted.

A second, quieter inconsistency sits behind this. `SuryToJsonSchema` renders an
optional field as `{"oneOf": [<T>, {"type": "null"}]}` — a published schema
saying null is a value this field takes, while the parser it describes rejects
it. That is what invites a client to send one.

### 2. The decode failure reaches the caller as "Unexpected error"

`CommandGenerator_Callback` produces a precise message —
`Error: Couldn't decode {…}: Failed parsing at ["deliveryWindow"]: …` — by
throwing a bare `Error`. graphql-yoga's `maskedErrors` (on whenever `debug` is
off, `GraphQL_ServerInstance.res:196`) replaces anything that is not a
`GraphQLError` with `Unexpected error` / `INTERNAL_SERVER_ERROR`.

So the server knows exactly what is wrong with the caller's input and answers
with the one thing they cannot act on. Masking is right for an internal failure
— a driver error should not become a caller-visible stack — but a payload that
fails to decode is the *caller's own input*, and `stampOwnerFields`' `Forbidden:
… the caller could not be identified` is likewise addressed to them. Both are
currently indistinguishable from a database outage.

This is why defect 1 took a live probe to find: from outside, a null argument
and a broken server look identical.

## Change

1. **Drop null-valued arguments where the payload is built.**
   `CommandGenerator_Callback.makeGenerateCommand` already normalises the
   argument dict in one place — it deletes `id` and stamps owner fields there,
   with the module's own note that a rule enforced on one transport and not the
   other "reads as enforced". Dropping null-valued keys joins them, so the local
   GraphQL resolvers, the AppSync path and the MCP tool handler all get it from
   one edit.

   Shallow, deliberately: a nested null inside an input object is a malformed
   value rather than an omission, and the one payload shape that can legitimately
   carry nulls is the permissive `S.json` direct-invocation schema, whose nulls
   are the caller's data. Named as the known limit rather than guarded against.

2. **Mark a caller-fault error so a transport can surface it.** `Plugin_ResolverError`
   — already the module for "a command that cannot be decoded", and already
   dependency-safe for the Lambda path — gains `throwCallerFault` /
   `isCallerFault`, which stamp and recognise a `name` on the thrown `Error`.
   The decode failure and the unidentified-owner refusal use it. Nothing else
   changes: an unmarked error stays masked, which is what masking is for.

3. **Surface it on the in-memory transport.** A new `GraphQL_CallerError` module
   holds the `GraphQLError` constructor that `Auth_GraphqlContext` already
   carried for its `Unauthorized` case, and the command resolvers rethrow a
   caller-fault error through it with `extensions.code: "BAD_USER_INPUT"`. The
   error reaches the client as a GraphQL error carrying the reason, which is the
   existing shape for "the command never reached the domain" — no change to the
   `CommandResult` union, so no lockstep with any client.

The AWS path needs no equivalent: an AppSync Lambda resolver's thrown message is
returned as the field error already, so marking the error is enough there.

## Acceptance

Automated and passing.

`CommandGeneratorCallbackTest` — the payload boundary: an optional field sent as
`null` publishes a command without the key and decodes; one carrying a value is
left exactly as sent; a null and an omission produce **the same commandJson**,
which is the claim the drop rests on; a null nested inside an opaque-JSON value
survives, so the drop is shallow. A payload that cannot decode is refused, marked
caller-fault, and its message names the field. `OwnerStampingTest` adds the
unidentified-owner refusal carrying the same mark.

`CommandAuthorizationTest` — the transport, through the registered resolver: a
caller-fault failure is rethrown as a `GraphQLError` with
`extensions.code: "BAD_USER_INPUT"`, carrying the reason it was given; an
unmarked failure is left alone to be masked, which is the control the mark exists
for.

Manual, against a platform built from this branch (a second in-memory instance on
its own ports, so the ordinary one was undisturbed), the same mutation three ways:

| `deliveryWindow` | before | after |
|---|---|---|
| explicitly null | `Unexpected error` | `CommandAccepted` |
| omitted | `CommandAccepted` | `CommandAccepted` |
| a value | `CommandAccepted` | `CommandAccepted` |

Three ways of saying the same thing, agreeing.

One link is covered by inference rather than a live run: that yoga passes a
`GraphQLError` through unmasked. The resolver is proven to construct one, and the
same constructor's `Unauthorized: requires group "Admin"` is observably reaching
clients today, which is the same path.

## Follow-up: the nullable rendering, and what looking at it found

The open question was whether `SuryToJsonSchema` should stop rendering an
optional field as `{"oneOf": [<T>, {"type": "null"}]}` — a published schema
saying null is a value, describing a parser that rejects one.

**It should stay.** Two reasons, both of which only became visible on inspection:

- It is the truth on the read side. A GraphQL response has no way to express
  "absent": a nullable field that has no value comes back as literal `null`. A
  read model's JSON Schema saying the value may be null is describing what a
  consumer will actually receive.
- It is no longer false on the write side. The command boundary now drops a null
  argument, so a caller who sends one *is* accepted — which is what the schema
  was already promising.

**It is also not redundant, which is where the real finding is.** The obvious
argument for removing it — that absence from `required` already says optional —
turns out to hold only at the top level. `optional` is computed for the schema
handed to `deriveObjectSchema` and is not threaded into `ObjectRef`, so **every
field of every nested record was published as required**, and the nullable
wrapper was the only thing saying otherwise. A generated form built from such a
schema refuses to submit without a field the domain never asked for — the exact
failure the `optional` plumbing was introduced for (`imageUrl?` as "a picture
every product had to have"), one level down and still live.

Fixed by answering the question from both sources: a field is optional when
`optional` names it — the only thing that can speak for a reference or a tagged
field, which classify as `EntityId` before their wrapper is examined — **or**
when its own IR type is nullable, read through a semantic wrapper. The second
half is what reaches a nested record.

Not fixed, and a narrower case of the same gap: a *nested* reference or tagged
optional field is still published as required, because for those the IR has
already collapsed the wrapper and there is no `optional` list one level in. No
schema in the repo has one; it needs the `optional` computation to become
recursive rather than a predicate change.

Covered by `SuryToJsonSchemaTest`: a nested record's optional field is not listed
as required, and its non-optional sibling still is.
