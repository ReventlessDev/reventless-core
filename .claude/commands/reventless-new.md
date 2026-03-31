---
description: Create a new Reventless platform with plugins from domain requirements
argument-hint: platform-name
---

# Create New Reventless Platform

Create a complete Reventless platform from domain requirements. This command guides you through requirements gathering, architecture decisions, and code generation.

## Workflow

### 1. Gather Requirements

Ask the user for:
- **Platform name** (use the argument if provided, otherwise ask)
- **Bounded contexts / plugins** — what domains does the app cover? (e.g., Catalog, Ordering)
- For each plugin:
  - **Entities** — what are the main domain objects?
  - **Commands** — what actions can users perform on each entity?
  - **Events** — what facts are recorded?
  - **Errors** — what can go wrong?
  - **Queries** — what views do users need?
- **Cross-plugin communication** — which plugins publish events for others?
- **Side effects** — email notifications, external APIs, data imports, automations?

### 2. Choose Architecture

For each entity, evaluate using the decision guide at `docs/guides/aggregate-vs-dcb-decision-guide.md`:
- Cross-entity state needed at decision time? → DCB
- Self-contained lifecycle? → Aggregate
- Synced from external plugin? → DCB
- Automation/translation needed? → DCB

Present the architecture summary to the user for confirmation before generating code.

### 3. Generate Code

Use the `reventless-app` skill to generate all files. Follow the platform-and-plugin guide at `docs/guides/platform-and-plugin-guide.md`.

Generate in this order:
1. Spec packages (extension point type definitions)
2. Plugin packages (package.json, rescript.json for each plugin)
3. Domain types (aggregate specs or slice files)
4. Business logic (behaviors or decide functions)
5. Read-side projections
6. Cross-plugin communication (EP specs, mappings, extensions)
7. Side effects and automation
8. Plugin composition roots
9. Platform Main.res
10. Tests

### 4. Build and Verify

```bash
npm install
npm run build
```

Check for zero warnings. Run tests in each plugin package.

### 5. Start the Platform

```bash
cd {platform-name}/{platform-name}
node src/Main.res.mjs
```

The platform starts with:
- GraphQL API on port 4000
- MCP server on port 3001
- Admin GraphQL on port 4001 (split mode)
- Admin MCP on port 3002 (split mode)

## Directory Structure Created

```
examples/{platform-name}/
├── {plugin1}-spec/         # Extension point type definitions
├── {plugin2}-spec/
├── {plugin1}/              # Plugin implementation
├── {plugin2}/
└── {platform-name}/        # Platform composition root
    └── src/
        └── Main.res
```
