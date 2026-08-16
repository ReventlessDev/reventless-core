// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  // Run first, understand later: the reader sees the shop working — locally and
  // in their own AWS account — before any source code appears.
  tutorialsSidebar: [
    'overview',
    'run-locally',
    'test-locally',
    'deploy-to-aws',
    'test-on-aws',
    {
      type: 'category',
      label: 'Understand the code',
      items: [
        'choosing-an-approach',
        {
          type: 'doc',
          id: 'hybrid-based',
          label: 'Hybrid walkthrough',
        },
        {
          type: 'category',
          label: 'Other approaches',
          items: [
            {
              type: 'doc',
              id: 'aggregate-based',
              label: 'Aggregate-based plugin',
            },
            {
              type: 'doc',
              id: 'dcb-based',
              label: 'DCB-based plugin',
            },
            'ai-generated',
          ],
        },
      ],
    },
  ],
};

export default sidebars;
