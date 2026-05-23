// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  tutorialsSidebar: [
    'get-started',
    'choosing-an-approach',
    {
      type: 'doc',
      id: 'hybrid-based',
      label: 'Hybrid walkthrough',
    },
    'run-locally',
    'test-locally',
    'deploy-to-aws',
    'test-on-aws',
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
};

export default sidebars;
