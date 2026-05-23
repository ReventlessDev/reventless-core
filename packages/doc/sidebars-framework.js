// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  frameworkSidebar: [
    'index',
    'get-started',
    'development-process',
    'ppx-binary-management',
    {
      type: 'link',
      label: 'ReScript Syntax',
      href: '/app/rescript-syntax',
    },
    {
      type: 'category',
      label: 'Architecture',
      items: [
        'architecture/aggregate-extension-connection',
        'architecture/dcb',
        'architecture/extension-point-protocol-versioning',
      ],
    },
    {
      type: 'category',
      label: 'Inner Workings',
      items: [
        'inner-workings/framework-inner-workings',
        'inner-workings/component-structure-pattern',
        'inner-workings/messages',
        'inner-workings/runtime',
        'inner-workings/pulumi',
        'inner-workings/resources',
        'inner-workings/serialization',
        'inner-workings/mcp',
      ],
    },
    {
      type: 'category',
      label: 'AI Skills',
      items: [
        'ai-skills/index',
        'ai-skills/writing-skills',
        'ai-skills/writing-commands',
        'ai-skills/writing-agents',
        'ai-skills/testing-skills',
        'ai-skills/updating-skills',
      ],
    },
    {
      type: 'category',
      label: 'Dev environment',
      items: [
        'contributing',
        'pnpm-guide',
        'cross-repo-dev-linking',
        'registry-and-tokens',
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
        'application-development-layers',
        'api-protocol-integration',
        'transport-adapter-guide',
        'component-testing',
        'd2-diagrams',
        'forward-codegen-pipeline',
        'graphql-schema-debugging',
        'output-types-in-reventless-spec',
        'reventless-vscode-testing',
      ],
    },
    {
      type: 'category',
      label: 'ReScript internals',
      items: [
        'rescript-namespaces-and-shadowing',
        'rescript-monorepo-build-behaviour',
        'rescript-option-proxy-pitfall',
      ],
    },
  ],
};

export default sidebars;
