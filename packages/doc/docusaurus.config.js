// @ts-check
// `@type` JSDoc annotations allow editor autocompletion and type checking
// (when paired with `@ts-check`).
// There are various equivalent ways to declare your Docusaurus config.
// See: https://docusaurus.io/docs/api/docusaurus-config

import { themes as prismThemes } from "prism-react-renderer";
import { readFileSync } from "fs";
import { join } from "path";

// Remark plugin that prepends shared D2 class definitions to every d2 code
// block before remark-d2 passes them to the d2 CLI.
//
// Why not use D2's native `...@file` import syntax in the markdown?
// The VS Code D2 preview extension writes code blocks to a temp file and calls
// d2 on it, so D2 resolves imports relative to the temp dir — unreachable from
// the project. By prepending here (before d2 ever sees the code) we get styled
// diagrams in Docusaurus without any import syntax in the markdown files.
// VS Code renders the same diagrams without the class styles (D2 silently
// ignores undefined classes), which means no errors and a functional preview.
function d2PrependStyles(opts = {}) {
  let styles = null;
  try {
    styles = readFileSync(opts.stylesPath, "utf8").trim();
  } catch (_) { /* file not found — skip silently */ }

  return (tree) => {
    if (!styles) return;
    const walk = (node) => {
      if (node.type === "code" && node.lang === "d2") {
        node.value = styles + "\n\n" + node.value;
      }
      if (node.children) node.children.forEach(walk);
    };
    walk(tree);
  };
}

// remark-d2 is ESM-only, so we load it via dynamic import in an async config.
async function createConfig() {
const d2 = (await import("remark-d2")).default;
const d2StylesPath = join(process.cwd(), "d2", "reventless.d2");

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Reventless",
  tagline: "Ship Value Fast",
  favicon: "img/logo.png",

  // Set the production url of your site here
  url: "https://reventlessdev.github.io",
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: "/reventless-core/",

  // GitHub pages deployment config.
  organizationName: "ReventlessDev", // Usually your GitHub org/user name.
  projectName: "reventless-core", // Usually your repo name.

  onBrokenLinks: "warn",
  onBrokenMarkdownLinks: "warn",

  // activate mermaid support
  // according to docusarus docs: https://docusaurus.io/docs/markdown-features/diagrams
  markdown: {
    mermaid: true,
  },

  themes: [
    "@docusaurus/theme-mermaid",
    [
      require.resolve("@easyops-cn/docusaurus-search-local"),
      {
        hashed: true,
        language: ["en"],
        indexDocs: true,
        indexBlog: false,
        docsRouteBasePath: ["/app", "/framework", "/cloud-provider", "/aws", "/online-shop"],
        // Enable search in dev mode by using the production index
        removeDefaultStopWordFilter: true,
        // Highlight search terms
        highlightSearchTermsOnTargetPage: true,
      },
    ],
  ],

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  plugins: [
    [
      "@docusaurus/plugin-content-docs",
      {
        // No id = this is the 'default' docs plugin instance.
        // Required so the search bar's useDocsData() hook can find it.
        path: "docs-app",
        routeBasePath: "app",
        sidebarPath: "./sidebars-app.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, { linkPath: "/reventless-core/d2" }]],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "framework",
        path: "docs-framework",
        routeBasePath: "framework",
        sidebarPath: "./sidebars-framework.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, { linkPath: "/reventless-core/d2" }]],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "cloud-provider",
        path: "docs-cloud-provider",
        routeBasePath: "cloud-provider",
        sidebarPath: "./sidebars-cloud-provider.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, { linkPath: "/reventless-core/d2" }]],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "aws",
        path: "docs-aws",
        routeBasePath: "aws",
        sidebarPath: "./sidebars-aws.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, { linkPath: "/reventless-core/d2" }]],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "online-shop",
        path: "docs-online-shop",
        routeBasePath: "online-shop",
        sidebarPath: "./sidebars-online-shop.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, { linkPath: "/reventless-core/d2" }]],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
  ],

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: false,
        /*
        blog: {
          showReadingTime: true,
          feedOptions: {
            type: ["rss", "atom"],
            xslt: true,
          },
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          editUrl:
            "https://github.com/facebook/docusaurus/tree/main/packages/create-docusaurus/templates/shared/",
        },
        */
        theme: {
          customCss: "./src/css/custom.css",
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      // Replace with your project's social card
      //image: 'img/docusaurus-social-card.jpg',
      navbar: {
        title: "Reventless",
        logo: {
          alt: 'Reventless Logo',
          src: 'img/logo.png',
        },
        items: [
          {
            type: "docSidebar",
            sidebarId: "appSidebar",
            position: "left",
            label: "App Guide",
          },
          {
            type: "docSidebar",
            sidebarId: "frameworkSidebar",
            docsPluginId: "framework",
            position: "left",
            label: "Framework",
          },
          {
            type: "docSidebar",
            sidebarId: "cloudProviderSidebar",
            docsPluginId: "cloud-provider",
            position: "left",
            label: "Cloud Providers",
          },
          {
            type: "docSidebar",
            sidebarId: "awsSidebar",
            docsPluginId: "aws",
            position: "left",
            label: "AWS",
          },
          {
            type: "docSidebar",
            sidebarId: "onlineShopSidebar",
            docsPluginId: "online-shop",
            position: "left",
            label: "Example",
          },
          {
            href: "https://github.com/ReventlessDev/reventless-core",
            label: "GitHub",
            position: "right",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "App Developer Guide",
            items: [
              {
                label: "Get Started",
                to: "/app/get-started",
              },
              {
                label: "Components",
                to: "/app/component-overview",
              },
            ],
          },
          {
            title: "Developer Guides",
            items: [
              {
                label: "Framework",
                to: "/framework",
              },
              {
                label: "Cloud Providers",
                to: "/cloud-provider",
              },
              {
                label: "AWS",
                to: "/aws",
              },
            ],
          },
          {
            title: "Resources",
            items: [
              {
                label: "ReScript",
                href: "https://rescript-lang.org/",
              },
              {
                label: "Pulumi",
                href: "https://www.pulumi.com/",
              },
              {
                label: "AWS Serverless",
                href: "https://aws.amazon.com/serverless/",
              },
            ],
          },
          {
            title: "More",
            items: [
              {
                label: "GitHub",
                href: "https://github.com/ReventlessDev/reventless-core",
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Reventless. Built for serverless.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ["rescript"],
      },
      mermaid: {
        options: {
          //maxTextSize: 50,
          // FIXME:
          themeCSS: `
            /* MESSAGES */
            .command > circle,
            rect[name="CommandSource"] {
              stroke: #66f;
              fill: #fff;
              r: 45px;
              }
            .command .nodeLabel,
            rect[name="CommandSource"] {
              color: #66f;
              }

            .event > circle {
              stroke: #fa0;
              fill:none;
              }
            .event .nodeLabel {
              color: #fa0;
              }

            /* REVENTLESS COMPONENTS */
            .aggregate > rect,
            rect[name="Aggregate"] {
              fill: #ff6;
              stroke: #333;
              }
            rect[name="Aggregate"] + text > tspan {
              color: #333;
            }

            .eventlog > rect,
            rect[name="CommandTopic"] {
              fill: #fa0;
              stroke: #333;
              }
            rect[name="CommandTopic"] + text > tspan {
              color: #333;
            }

            .eventlog > rect,
            rect[name="EventLog"] {
              fill: #fa0;
              stroke: #333;
              }
            rect[name="EventLog"] + text > tspan {
              color: #333;
            }

           .eventtopic > rect,
            rect[name="EventTopic"] {
              fill: #b97c01;
              stroke: #333;
              }
            rect[name="EventTopic"] + text > tspan {
              fill: #fff;
            }

            .readmodel > rect {
              fill: #9c5;
              stroke: #333;
              }
            .readmodel .nodeLabel {
              color: #333;
            }

            .eventlog > path {
              fill: #fa0;
              }
            .eventlog .nodeLabel {
              }

            .eventtopic > rect {
              fill: #b97c01;
              }
            .eventtopic .nodeLabel {
              }

            .eventtopic > rect {
              fill: #b97c01;
              }
            .eventtopic .nodeLabel {
              }

            .eventcollector > rect {
              fill: #bda677;
              }
            .eventcollector .nodeLabel {
              }

            .eventmapper > rect {
              fill: #99f;
              stroke: #fa0;
              }
            .eventmapper .nodeLabel {
              }

            .task > rect {
              fill: #f9f;
              stroke:#333;
              }
            .task .nodeLabel {
              color: #333;
            }

            .sideeffecthandler > rect {
              fill: #f9f;
              stroke: #ff0;
              }
            .sideeffecthandler .nodeLabel {
            }

            .commandtopic > rect {
              fill: #88ccff;
              /*fill: #fff;*/
              }
            .commandtopic .nodeLabel {
              /*color: #66f;*/
              }

            .commandgenerator > rect {
              fill: #88ccff;
              }
            .commandgenerator .nodeLabel {
              /*color: #66f;*/
              }

            .client > rect {
            /* TODO */
            }

            /* HELPER */
            .parameter > rect,
            rect[name="Behavior"] {
              fill: #f90;
              stroke: #f90;
            }
            .target > rect,
            .source > rect {
              stroke: none;
              fill: none;
            }
            `,
        },
      },
    }),
};

return config;
}

export default createConfig;
