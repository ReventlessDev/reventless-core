# Docusaurus Mermaid: "Hook is called outside the `<ColorModeProvider>`"

## Affected packages

`packages/doc`

## Symptom

Navigating to any page that contains a Mermaid diagram shows a React error:

```
Hook is called outside the <ColorModeProvider>.
Please see https://docusaurus.io/docs/api/themes/configuration#use-color-mode.
```

The diagram fails to render. Pages without Mermaid diagrams are unaffected.

## Root cause

`@docusaurus/theme-mermaid` calls `useColorMode()` (from `@docusaurus/theme-common`)
to pick the diagram theme. React context lookup uses **object identity**: the
`ColorModeContext` object that `useColorMode()` reads must be the same object
that `ColorModeProvider` wrote.

This breaks when `@docusaurus/theme-common` is loaded as **multiple module
instances** from different file paths, even at the same version.

In this monorepo, the chain of events was:

1. `@easyops-cn/docusaurus-search-local@0.55.0` depends on
   `@docusaurus/theme-common@3.5.2`.
2. All `@docusaurus` packages at 3.9.2 need `@docusaurus/theme-common@3.9.2`.
3. Because 3.5.2 ≠ 3.9.2, npm installed 3.5.2 at the workspace root and gave
   every `@docusaurus` 3.9.2 package its own **nested** copy of 3.9.2 at a
   different file path.
4. `@docusaurus/theme-classic` loaded `ColorModeContext` from its nested copy;
   `@docusaurus/theme-mermaid` loaded `useColorMode()` from a different nested
   copy. Different file paths → different JS objects → context lookup fails.

## Fix

Add a root-level npm `overrides` entry in `/package.json` to force a single
shared version:

```json
"overrides": {
  "@docusaurus/theme-common": "3.9.2"
}
```

Then run `npm update @docusaurus/theme-common` (or `npm install`) from the
workspace root. npm deduplicates all nested copies into one shared instance at
`node_modules/@docusaurus/theme-common@3.9.2`, which every package resolves to.

## When this recurs

The underlying trigger is `@easyops-cn/docusaurus-search-local` depending on an
older minor of `@docusaurus/theme-common` than the rest of Docusaurus. Once the
search plugin releases a version aligned with the current Docusaurus minor, the
`overrides` entry can be removed.

Until then, when upgrading Docusaurus, bump the override version to match:

```json
"overrides": {
  "@docusaurus/theme-common": "<new-docusaurus-version>"
}
```
