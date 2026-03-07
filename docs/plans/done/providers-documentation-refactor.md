# Plan: Refactor Documentation Site — Providers Section

## Goal

Replace the separate top-level "Cloud Providers" and "AWS" navbar links with a single "Providers" link. Under that link, the sidebar should contain:

1. An **Overview** page (the general concept of providers, existing and future providers)
2. An **InMemory** section (documenting `reventless-in-memory`)
3. An **AWS** section (the existing AWS adapter documentation)

The existing "Cloud Providers" content (adapter pattern, scaffolding guide) becomes part of the Overview area.

## Current State

- **Navbar** has two separate links: "Cloud Providers" (`/cloud-provider`) and "AWS" (`/aws`)
- **`docs-cloud-provider/`** contains 3 pages: `index.md`, `get-started.md`, `adapter-pattern.md`
- **`docs-aws/`** contains 14 pages: `index.md`, `get-started.md`, and 12 adapter docs in `adapters/`
- **`sidebars-cloud-provider.js`** and **`sidebars-aws.js`** are separate sidebar configs
- **No `docs-in-memory/`** directory exists yet
- `docusaurus.config.js` has two separate `plugin-content-docs` instances for `cloud-provider` and `aws`

## Steps

### Step 1: Create unified docs directory structure

Merge content into a single `docs-providers/` directory:

```
packages/doc/docs-providers/
├── index.md                          # NEW — Provider overview (concept + list of providers)
├── get-started.md                    # FROM docs-cloud-provider/get-started.md (scaffolding guide)
├── adapter-pattern.md                # FROM docs-cloud-provider/adapter-pattern.md
├── in-memory/
│   ├── index.md                      # NEW — InMemory provider overview
│   ├── get-started.md                # NEW — Getting started with reventless-in-memory
│   └── adapters/                     # NEW — InMemory adapter docs (stub or write)
│       ├── eventlog.md
│       ├── commandtopic.md
│       ├── eventtopic.md
│       ├── eventcollector.md
│       ├── querydb.md
│       ├── task.md
│       ├── commandgenerator.md
│       ├── counter.md
│       ├── heartbeat.md
│       ├── queryengine.md
│       ├── scheduledpublisher.md
│       ├── sideeffecthandler.md
│       └── dcbeventlog.md
├── aws/
│   ├── index.md                      # FROM docs-aws/index.md
│   ├── get-started.md                # FROM docs-aws/get-started.md
│   └── adapters/                     # FROM docs-aws/adapters/ (all 12 files)
│       ├── eventlog.md
│       ├── commandtopic.md
│       ├── eventtopic.md
│       ├── eventcollector.md
│       ├── querydb.md
│       ├── task.md
│       ├── commandgenerator.md
│       ├── counter.md
│       ├── heartbeat.md
│       ├── queryengine.md
│       ├── scheduledpublisher.md
│       └── statetopic.md
```

### Step 2: Write the Provider Overview page (`docs-providers/index.md`)

Content should cover:
- What providers are in Reventless (adapter implementations for specific platforms)
- The two-layer model (deploy-time vs runtime) — summarize from existing cloud-provider index
- Link to the adapter pattern page for details
- **Existing providers:**
  - **InMemory** (`reventless-in-memory`) — for local development and testing, no cloud infrastructure needed
  - **AWS** (`reventless-aws`) — production provider using DynamoDB, SQS, SNS, S3, Lambda
- **Future providers** (planned/possible):
  - Azure, GCP, Cloudflare Workers, or other serverless platforms
  - Community contributions welcome

### Step 3: Write the InMemory provider docs

#### `in-memory/index.md`
- Purpose: local development and unit/integration testing without cloud infrastructure
- Package: `reventless-in-memory`
- Key features: in-memory bus, synchronous event processing, test runner utilities
- Service mappings table (similar to AWS's table but for in-memory implementations)

#### `in-memory/get-started.md`
- Installation and setup
- Creating an InMemory platform
- Running tests with the in-memory provider
- Reference existing test patterns from the codebase

#### `in-memory/adapters/*.md` (one per adapter — mirrors AWS adapter list)
- Adapters: eventlog, commandtopic, eventtopic, eventcollector, querydb, task, commandgenerator, counter, heartbeat, queryengine, scheduledpublisher, sideeffecthandler, dcbeventlog
- Each page documents:
  - What it replaces (vs the AWS equivalent)
  - How it works (in-memory data structures)
  - Test usage patterns
  - Key differences from the production (AWS) adapter

### Step 4: Create unified sidebar (`sidebars-providers.js`)

```js
const sidebars = {
  providersSidebar: [
    'index',
    'get-started',
    'adapter-pattern',
    {
      type: 'category',
      label: 'InMemory',
      items: [
        'in-memory/index',
        'in-memory/get-started',
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'in-memory/adapters/eventlog',
            'in-memory/adapters/commandtopic',
            'in-memory/adapters/eventtopic',
            'in-memory/adapters/eventcollector',
          ],
        },
        {
          type: 'category',
          label: 'Data Storage',
          items: [
            'in-memory/adapters/querydb',
            'in-memory/adapters/task',
          ],
        },
        {
          type: 'category',
          label: 'Supporting Services',
          items: [
            'in-memory/adapters/commandgenerator',
            'in-memory/adapters/counter',
            'in-memory/adapters/heartbeat',
            'in-memory/adapters/queryengine',
            'in-memory/adapters/scheduledpublisher',
            'in-memory/adapters/sideeffecthandler',
          ],
        },
        {
          type: 'category',
          label: 'DCB',
          items: [
            'in-memory/adapters/dcbeventlog',
          ],
        },
      ],
    },
    {
      type: 'category',
      label: 'AWS',
      items: [
        'aws/index',
        'aws/get-started',
        {
          type: 'category',
          label: 'Core Event Sourcing',
          items: [
            'aws/adapters/eventlog',
            'aws/adapters/commandtopic',
            'aws/adapters/eventtopic',
            'aws/adapters/eventcollector',
          ],
        },
        {
          type: 'category',
          label: 'Data Storage',
          items: [
            'aws/adapters/querydb',
            'aws/adapters/task',
          ],
        },
        {
          type: 'category',
          label: 'Supporting Services',
          items: [
            'aws/adapters/commandgenerator',
            'aws/adapters/counter',
            'aws/adapters/heartbeat',
            'aws/adapters/queryengine',
            'aws/adapters/scheduledpublisher',
            'aws/adapters/statetopic',
          ],
        },
      ],
    },
  ],
};
export default sidebars;
```

### Step 5: Update `docusaurus.config.js`

1. **Remove** the two separate plugin instances for `cloud-provider` and `aws`
2. **Add** a single plugin instance:
   ```js
   {
     id: "providers",
     path: "docs-providers",
     routeBasePath: "providers",
     sidebarPath: "./sidebars-providers.js",
     // ... same remarkPlugins/rehypePlugins
   }
   ```
3. **Update navbar**: Replace the two items ("Cloud Providers" and "AWS") with one:
   ```js
   {
     type: "docSidebar",
     sidebarId: "providersSidebar",
     docsPluginId: "providers",
     position: "left",
     label: "Providers",
   }
   ```
4. **Update footer**: Replace the "Cloud Providers" and "AWS" links with a single "Providers" link to `/providers`
5. **Update search config**: Replace `"/cloud-provider", "/aws"` with `"/providers"` in `docsRouteBasePath`

### Step 6: Update cross-references

Search all `.md` files for links to `/cloud-provider/` and `/aws/` and update them to `/providers/` and `/providers/aws/` respectively:
- `/cloud-provider` → `/providers`
- `/cloud-provider/get-started` → `/providers/get-started`
- `/cloud-provider/adapter-pattern` → `/providers/adapter-pattern`
- `/aws` → `/providers/aws`
- `/aws/adapters/eventlog` → `/providers/aws/adapters/eventlog`
- etc.

### Step 7: Clean up old files

- Delete `docs-cloud-provider/` directory
- Delete `docs-aws/` directory
- Delete `sidebars-cloud-provider.js`
- Delete `sidebars-aws.js`

### Step 8: Verify

- Run `cd packages/doc && npm run build` to check for broken links
- Fix any warnings from `onBrokenLinks: "warn"` and `onBrokenMarkdownLinks: "warn"`
- Verify sidebar renders correctly with Overview, InMemory, and AWS sections

## Notes

- The InMemory adapter docs will need to reference the actual implementations in `reventless/reventless-in-memory/`
- AWS adapter content moves as-is with only path updates in frontmatter (if any `sidebar_position` or cross-links)
- The existing cloud-provider content (adapter pattern, scaffolding) remains useful as general provider development guidance under the top-level providers section
