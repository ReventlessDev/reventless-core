# Contributing to the documentation

## Where a page belongs

Five sections, one audience each — see the [README](./README.md). Put a page
where its reader is, not where its subject lives: infrastructure components an
application developer never writes belong in Contributing, even though they are
components.

## Rules that the build enforces

- **Broken links and anchors fail the build.** Moving or renaming a page means
  adding a redirect in `docusaurus.config.js`.
- **Every page belongs to a sidebar.** An orphan page is reachable only by URL.

## Rules that it does not

- **Verify claims against source**, never against another page — doc-to-doc
  reconciliation is how contradictions start. If you cannot check it, do not
  write it.
- **Do not document anything outside this repository's published packages.** No
  sibling-repo file paths, no internal plan citations, no install instructions
  for something unpublished.
- **Do not hardcode versions in prose.** Say where to read the pin instead; a
  quoted version is wrong within a release or two.
- **D2 diagrams fail silently.** A diagram that does not compile leaves no image
  and no build error — check `static/d2/<page>/` after adding one. Use the
  semantic classes from `d2/reventless.d2`, never raw colours.
