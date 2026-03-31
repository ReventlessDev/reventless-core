// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  frameworkSidebar: [
    'index',
    'get-started',
    'development-process',
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
      label: 'AI Skills Development',
      items: [
        'ai-skills/index',
        'ai-skills/writing-skills',
        'ai-skills/writing-commands',
        'ai-skills/writing-agents',
        'ai-skills/testing-skills',
        'ai-skills/updating-skills',
      ],
    },
  ],
};

export default sidebars;
