---
title: Updating Skills
sidebar_position: 6
---

# When to Update Skills

Skills encode framework knowledge. When the framework changes, skills must be updated to stay accurate.

## Triggers for Skill Updates

| Framework Change | Skills to Update |
|-----------------|------------------|
| New component type added | `reventless-app` (component-catalog.md), `event-sourcing-cqrs` (concept-map.md) |
| Component spec changed | `reventless-app` (relevant pattern file) |
| New compiler warning pattern | `rescript` (common-pitfalls.md) |
| ReScript version upgrade | `rescript` (syntax-quick-reference.md) |
| sury-ppx behavior change | `rescript` (sury-ppx-patterns.md) |
| New AWS adapter | `reventless-aws` (adapter-architecture.md) |
| New deployment strategy | `reventless-aws` (runtime-patterns.md) |
| Plugin composition pattern change | `reventless-app` (aggregate-patterns.md, dcb-patterns.md) |
| Testing DSL change | `reventless-testing` (behavior-test-dsl.md) |
| New naming convention | `reventless-context` (discovery-checklist.md) |

## Update Process

1. **Update the reference file** in `.claude/skills/{skill}/references/`
2. **Update the corresponding Docusaurus page** if one exists
3. **Commit both in the same PR** to prevent drift

## Keeping Skills and Docs in Sync

Skills and Docusaurus docs serve different audiences:

| Content | Location | Audience |
|---------|----------|----------|
| AI instructions and code templates | `SKILL.md` + `references/` | The AI assistant |
| Human tutorials ("how to collaborate with the AI") | `docs-app/ai-assisted/` | App developers |
| Skill maintenance guides | `docs-framework/ai-skills/` | Framework developers |

**Do not duplicate.** Existing guides like `docs/guides/aggregate-vs-dcb-decision-guide.md` are shared — both AI and humans read them. Skills reference these files by path rather than copying content.

## Versioning

The plugin version in `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json` should be bumped when skills are updated. Follow semantic versioning:

- **Patch** — typo fixes, clarifications, minor reference updates
- **Minor** — new reference files, new skills, expanded coverage
- **Major** — breaking changes to skill activation or command behavior
