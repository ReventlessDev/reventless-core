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
  ],
};

export default sidebars;
