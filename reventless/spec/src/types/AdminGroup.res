/**
The group whose members administer a deployment.

One definition, because the name is decided **twice and independently**: an
authorization rule names it to allow a read, and [OwnerScope.elevatedGroups]
names it to exempt a caller from `@owner` narrowing. Nothing checks that the two
agree, and a deployment where they disagree is refused nowhere — the
administrator passes every authorization check and then reads *empty views*,
because every owner-scoped view filters them out. Empty-because-scoped and
empty-because-there-is-nothing look identical from outside.

In `spec` rather than in a provider package because **both platforms hard-code
it**: the AWS platform decorates its admin API with it, while the local platform
both wraps its `Platform_*` fields in it and hands it to the built-in developer
account. A constant only one of them could reach would leave the other exactly as
divergent as it is today.

🚨 **This buys agreement, not the freedom to rename.** `"Admin"` is written into
every example's `@@reventless.authorize` annotations, and a PPX annotation takes a
literal — so the consumers that matter most *cannot* read this constant. Changing
the value here would leave those annotations behind and silently split the two
mechanisms this exists to hold together, which is the failure above rather than a
compile error. Renaming the administrator group is a different and much larger
act. `AdminGroupTest` asserts that the constant and the platform's own annotation
still say the same thing, because that boundary can carry no other check.
*/
let name = "Admin"
