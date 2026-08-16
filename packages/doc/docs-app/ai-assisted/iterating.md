---
title: Iterating on Generated Code
sidebar_position: 6
---

# Iterating on Generated Code

Generated code is a starting point. Here's how to evolve it.

## Adding Components

Use `/reventless-add` to add components to an existing plugin:

```
/reventless-add slice       → new StateChangeSlice
/reventless-add viewslice   → new StateViewSlice
/reventless-add aggregate   → new Aggregate (spec + behavior)
/reventless-add readmodel   → new ReadModel (spec + projection)
/reventless-add automation  → new AutomationSlice
/reventless-add inbound     → new InboundTranslationSlice
/reventless-add outbound    → new OutboundTranslationSlice
/reventless-add extension   → subscribe to another plugin's EP
/reventless-add extensionpoint → expose events to other plugins
/reventless-add plugin      → new plugin + spec package
```

The AI detects your existing project structure and generates only what's needed, automatically updating the plugin composition root.

## Modifying Business Logic

### Adding a New Command

Describe what you want:

> "Add an ArchiveProduct command that marks a product as archived. Archived products should reject all other commands."

The AI will:
1. Add the command and event variants
2. Update the state type and evolve function
3. Add guard conditions in decide
4. Update the view slice to reflect archive status
5. Add tests

### Changing Validation Rules

> "PlaceOrder should also verify that the customer has a verified email."

The AI will update the decide function and add any necessary consumed events.

### Adding Cross-Plugin Communication

> "The Shipping plugin needs to know when orders are shipped."

The AI will:
1. Create an extension point spec in `ordering-spec/`
2. Add EP mapping in the Ordering plugin
3. Create an extension in the Shipping plugin
4. Wire everything in both plugin composition roots

## Validation After Changes

Always validate after making changes:

```
/reventless-validate
```

This catches:
- Missing `@schema` annotations
- Missing `@s.matches(DcbTag.string)` markers
- Components not registered in plugin composition
- Compiler warnings

## Rebuilding

After any code change:

```bash
pnpm run build    # compile all packages
pnpm test         # run all tests
```

If you've reorganized files (moved, renamed):

```bash
npx rescript clean && pnpm run build
```

## When to Regenerate vs Modify

| Situation | Approach |
|-----------|----------|
| Add a field to an existing command | Modify the `.res` file directly |
| Add a new command to existing entity | Ask the AI — it updates multiple files |
| Add a new entity to existing plugin | Use `/reventless-add` |
| Add a new plugin | Use `/reventless-add plugin` |
| Major domain restructure | Consider `/reventless-new` for a fresh start |
| Fix a bug in business logic | Modify the decide/evolve function directly |
