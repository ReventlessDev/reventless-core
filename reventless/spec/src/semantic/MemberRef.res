/**
A reference to a member of a collection the row already holds.

The distinction this type exists to make is **input versus selection**. A field
typed {!UploadableImage} says "give me a new file", and a UI reading it binds an
upload endpoint. A field that must name a picture the row *already has* — remove
this one, make that one primary, caption the third — says something else
entirely, and before this type there was no way to say it: every such field was
typed as the uploadable it selected among, so every one of them offered an
uploader. On a remove command that is not merely odd, it is the opposite of what
the command does.

## What it declares, and what it does not

It declares where the candidates are: a field of the row, by name. It declares
no store — nothing is provisioned, no upload endpoint is bound — for the same
reason {!ImageRef} declares none, and with the same consequence: a consumer
asking `StorageRef.getFieldStore` gets `None`.

The *semantic* is content-agnostic: one id serves images and documents, and what
a member is comes from `~content`. That argument is optional and, where a caller
gives it, redundant with the collection's own element type — deliberately, and
for the reason {!UploadableImage} exists at all rather than a storage ref beside
a content annotation. A consumer rendering one cell holds that field's schema and
nothing else; it cannot reach a sibling's element type, so a declaration that
made it look would be a declaration it could not read. Omit it and such a
consumer falls back to its own rules, which is the right answer for a member type
this vocabulary has no word for.

## Why not `Reference.to_`

A reference resolves its candidates by querying the target view's table. These
candidates are on the row already in hand, so there is no query: same shape of
answer, different resolution path, and pointing a query at it would scan a table
to re-read a value the caller is holding. `Reference.toWithoutDcbTag` is the
precedent that a payload can be reused without dragging DCB tagging along; this
is the converse — a payload that resolves locally.

## Where it goes

**On a command field**, and there it means *pick one of these*:

```rescript
@schema type command =
  | RemoveProductImage({
      productId: @s.matches(DcbTag.string) string,
      productImage: @s.matches(Reventless.MemberRef.of_(~view="Products", ~field="productImages")) string,
    })
```

`~view` names the collection's view. Omit it on a declaration made *on* that
view's own state, where the answer is "this record" — the wrapper walk below
supports that position, and `getFieldTarget` reads it. Nothing in the framework
declares one there today: a view that carried a scalar *and* the set it was
drawn from needed a marker saying the two were one thing, and a view whose
primary is simply the first member has no second field to reconcile.
*/

/** Transparent `string`, as every ref-shaped semantic here is: the marker
    refines an existing field rather than replacing it, so nothing stored
    changes when a field adopts it. */
type t = string

external unsafe: string => t = "%identity"
external toString: t => string = "%identity"

/** Which collection a field names a member of. */
type target = Semantic.memberTarget

/**
The sury schema for a field that selects a member of `field`.

`~view` names the collection's view; omit it on a declaration made *on* that
view's own state, where the answer is "this record". `~plugin` qualifies a view
another plugin owns. `~content` names what the members are — pass
`Semantic.Id.imageRef` for a set of pictures — so a reader holding this field
alone still knows what it is drawing.

No grammar is checked. The value is whatever the collection's own element type
admits — a storage ref today, and checking the ref grammar a second time here
would put {!StorageRef}'s rules in a second place to drift from. What makes a
selection valid is that the row holds it, and only the decider knows that.
*/
let of_ = (
  ~plugin: option<string>=?,
  ~view: option<string>=?,
  ~content: option<string>=?,
  ~field: string,
): S.t<t> =>
  S.string->Semantic.mark(
    ~id=Semantic.Id.memberRef,
    ~payload=MemberOf({view, field, plugin, content}),
  )

/** The collection a schema names, if it carries the marker. */
let getTarget = (schema: S.t<'a>): option<target> =>
  switch Semantic.get(schema) {
  | Some({payload: MemberOf(target)}) => Some(target)
  | _ => None
  }

/**
The collection a *field* names, looking through the wrappers around its value.

The distinction `Reference.getFieldTarget` draws applies here for the same
reason: `of_` returns an element schema, so on an `array<string>` of selections
the marker sits on the string inside the array and the field's own schema
carries nothing. Only the optional wrapper and the array element are followed —
a marker on a nested record's field belongs to that field.
*/
let rec getFieldTarget = (schema: S.t<unknown>): option<target> =>
  switch getTarget(schema) {
  | Some(_) as found => found
  | None =>
    switch schema->Semantic.unwrapOptional->Option.getOr(schema) {
    | Array({additionalItems: Schema(item)}) => getFieldTarget(item)
    | _ => None
    }
  }
