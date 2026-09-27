# Plan (Backlog): an identity the plugin declares is not a dangling reference

**Status:** Backlog (not started)

In plain words: a field typed by an identity (`siteId: SiteId.t`) is linked to the view keyed
by that identity. When the plugin has no such view, platform start warns that the field
"references nothing". That warning is right when the identity belongs to another plugin and the
field needs an `@ref`. It is noise when the plugin declares the identity itself and simply has
no view listing it yet.

## Where it is today

`Plugin_Structure.identityReference` reports a field typed by an identity that no view in the
plugin is keyed by: "`siteId` is a SiteId, and no view in this plugin is keyed by it, so it
references nothing". `identityViews.report` sends every such message to `log.warn`, once per
message, at every platform start.

"Declared nowhere" is not a case that can happen: a field typed `SiteId.t` only compiles when
`SiteId` exists. The distinction that matters is where it is declared:

- **In this plugin** (`src/**/SiteId.res`, `include Reventless.Id.Make({let key = "siteId"})`).
  The plugin owns the identity. No view keyed by it is a gap the author may intend: a site that
  other parts name but no screen lists.
- **Elsewhere**, usually another plugin's spec package (`ProductId` from `catalog-spec`). The row
  lives in the other plugin, and the field needs `@ref("Catalog.Products")` to link. The warning
  and its advice are right here.

Nothing at runtime says which case applies. The schema carries only the key (`IdentityOf({key})`),
and `Plugin_Structure` never sees files.

## Change

1. **The generator passes the plugin's own identities.** `generate-plugin` finds each
   `src/**/<Name>Id.res` whose source includes `Id.Make`, and emits
   `~identities=[CategoryId.key, OrderId.key]` on `Plugin.make`. It references the modules, so
   the key comes from the compiler rather than from parsing a string out of the source.
   `Plugin.make` takes it as an optional argument, so a `Plugin.res` generated before this change
   keeps compiling and keeps today's warning.
2. **`identityViews` carries them** as `ownIdentities: array<string>`.
3. **The report splits by case.** In the no-view case, a key in `ownIdentities` logs the same
   sentence through `log.info`. Any other key keeps `log.warn`. The several-views case and the
   `@ref`-names-the-wrong-view case stay warnings in both, since both are real ambiguities.
4. **Regenerate the examples' committed `src/Plugin.res`** in the same commit.

## Verify

- A plugin that declares `SiteId`, has a field typed by it, and has no Sites view starts with
  no warning and logs the sentence as information.
- The same field typed by an identity from a spec package, with no view and no `@ref`, still
  warns.
- A `Plugin.res` without `~identities` still compiles and still warns.
