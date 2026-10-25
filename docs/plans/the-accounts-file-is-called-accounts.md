# Plan: the accounts file is called accounts

**Date:** 2026-10-25<br/>
**Status:** ✅ [AF1](#af1-the-file-is-found-by-its-new-name-and-its-old-one) to
[AF4](#af4-the-code-names-follow) built 2026-10-25.

**Id prefixes.** The steps are numbered AF1 to AF4; AF stands for *accounts file*.

---

## Why

The file a platform reads its accounts from is called `.reventless/users.yaml`, its committed
template `users.example.yaml`. Everything else about it already says *accounts*: its format is
`AccountsManifest`, the command that makes the accounts on AWS is `provision-accounts`, and the
authoring tools speak of adding an account. A reader meets two words for one thing, and the file
name is the one they see first.

`username` and `userId` stay: they are the names identity providers and tokens use for an entry's
fields, not the name of the file.

## Rules every step keeps

1. **An app that exists keeps working.** Every app made so far has a committed
   `users.example.yaml` and a live `.reventless/users.yaml`. Both are read until they are renamed,
   and the platform says once that they should be.
2. **One place knows the names.** `AccountsManifest` holds the file name, the template name and
   the old ones; every reader asks it.
3. **A new file is always written under the new name.**

## Steps

### AF1: the file is found by its new name, and its old one

- `AccountsManifest.fileName = "accounts.yaml"`, `templateName = "accounts.example.yaml"`, and the
  old names beside them.
- `defaultPath()` answers `.reventless/accounts.yaml` when it exists, else `.reventless/users.yaml`
  when that exists, saying once on the console that it is read under its old name and how to
  rename it; else the new name, for a file about to be made.
- A template is found as `accounts.example.yaml`, else `users.example.yaml`
  (`templateIn(dir)`), for preparing the live file and for a deployment.
- The seed reads its accounts through `AccountsManifest.defaultPath` rather than spelling the path
  itself.

**Exit:** `AccountsManifestTest`: each name found, the old one with the notice once, a new file
made under the new name from either template.

### AF2: the local platform and AWS read through it

The in-memory login, its file watch, the identity provider over the file, `prepare-accounts`,
`provision-accounts` and the deploy's template check already ask `AccountsManifest`; their
messages name the new file.

**Exit:** the existing tests, moved to the new name, and one reading an app that has only the old
files.

### AF3: the examples, scripts and docs say accounts

The examples' templates are renamed (`git mv`), `scripts/setup.mjs` seeds `accounts.yaml`, and
the guides, plans and comments that name the file name it so.

**Exit:** no `users.yaml` left in the repository but in the old-name fallback, its tests and this
plan. Plans already done and analyses keep the name they were written with.

**Built 2026-10-25.** `AccountsManifest.defaultPath` and `templateIn` find either name, with
`noticeOldName` saying once which file was read; the seed keeps a copy of the lookup, as it does
not depend on the spec package; the AWS deploy's per-stack record is `accounts.<stack>.yaml`, its
old `users.<stack>.yaml` read the same way. Tested in `PrepareAccountsTest` (the old names read, a
new file made under the new name from an old template, the new name preferred when both are
there).

### AF4: the code names follow

`UserStore`, `Seed_Users`, the store's `~users` / `~usersFile` and
`Capability_IdentityProvider_UserStore` become `AccountStore`, `Seed_Accounts`, `~accounts` /
`~accountsFile` and `Capability_IdentityProvider_AccountStore`, with their tests; the store's
answers `InlineUsers` and `UsersFile` become `InlineAccounts` and `AccountsFile`. The AWS and
Cognito names (`Cognito_UserPool`, `Util_CognitoGroupUser`) and `Auth_UserId` stay: they are the
provider's words and the entry's field.

An app's own `Main.res` names the identity provider when it lists the registration chapter: the
example's is renamed here, and an app made by the authoring tools gets the new name once they
follow this release.

**Built 2026-10-25**, in the same change as [AF1](#af1-the-file-is-found-by-its-new-name-and-its-old-one)
to [AF3](#af3-the-examples-scripts-and-docs-say-accounts): a clean rename, no old module kept,
as no app outside this repository names the store yet.

## Open questions

1. **When does the old name stop being read?** **Recommendation: after two releases that print the
   notice**, removed in a commit of its own, so an app that missed the notice gets an error naming
   both files rather than an empty login.
2. *Settled 2026-10-25: yes.* **Does AF4 go in the same release as AF1?** No app outside this
   repository names the store yet, so the code names follow the file in one release.
