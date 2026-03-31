---
title: Getting Started
sidebar_position: 2
---

# Getting Started with AI-Assisted Development

## Quick Start

1. **Open your Reventless project** in an AI assistant (Claude Code, Cursor, Copilot, or Codex)

2. **Describe your domain:**

   > "Create a Catalog plugin with Products and Categories. Products can be added, renamed, and priced. Categories can be created and archived. Other plugins need to know when products become available or change price. Use DCB."

3. **The AI will:**
   - Analyze your domain and choose the right architecture
   - Present a design summary for your confirmation
   - Generate all files (specs, slices, views, extension points, tests, config)
   - Build and verify the code compiles with zero warnings

4. **Start your platform:**
   ```bash
   cd your-platform/your-platform
   node src/Main.res.mjs
   ```

## Using Slash Commands

### `/reventless-new` — Create a New Platform

Scaffolds an entire platform from scratch:

```
/reventless-new online-shop
```

The assistant walks you through requirements gathering, architecture decisions, and code generation.

### `/reventless-add` — Add a Component

Adds a component to an existing plugin:

```
/reventless-add slice
/reventless-add readmodel
/reventless-add extensionpoint
```

Detects your project structure and generates only what's needed, updating the plugin composition root automatically.

### `/reventless-validate` — Validate Your Project

Checks structure, naming, annotations, and compilation:

```
/reventless-validate
```

Reports errors (must fix) and warnings (should fix) with specific file locations and fix instructions.

## Tips for Better Results

- **Be specific about entities and their operations** — "Products can be added, renamed, and priced" is better than "manage products"
- **Mention cross-plugin needs** — "Other plugins need to know when products become available" triggers extension point generation
- **State the architecture preference** — "Use DCB" or "Use aggregates" if you have a preference; otherwise the AI decides based on your requirements
- **Describe side effects** — "Send a confirmation email when an order is placed" triggers OutboundTranslationSlice generation
