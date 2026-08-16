import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import HomepageFeatures from '@site/src/components/HomepageFeatures';

import Heading from '@theme/Heading';
import styles from './index.module.css';

function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <header className={clsx('hero', styles.heroBanner)}>
      <div className="container">
        <Heading as="h1" className={styles.heroTitle}>
          {siteConfig.title}
        </Heading>
        <p className={styles.heroSubtitle}>
          The spec-driven event platform — focus on your business, not technology
        </p>
        <p className={styles.heroDescription}>
          Describe your domain as specs — the commands, events, and views your
          business is made of — and as scenarios that pin the rules down and run
          as tests. Reventless derives the rest: an event-sourced store with a
          full audit trail, live read models, GraphQL and MCP APIs, a generated
          UI, and the cloud infrastructure to run it. One source of truth, no glue
          code. Deploy to your own AWS account today, with a provider seam built
          for sovereign and on-premise targets. Open source, self-hosted, and
          AI-native. Built on ReScript, Pulumi, and AWS serverless.
        </p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/why/">
            Why Reventless
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/tutorials/get-started">
            Try the example
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/app/get-started">
            Build an app
          </Link>
        </div>
      </div>
    </header>
  );
}

const ReadingPaths = [
  {
    persona: 'Evaluator',
    question: '“What is Reventless? Could I use it for my development?”',
    steps: [
      <><Link to="/why/">What is Reventless</Link> — the model, in plain language</>,
      <><Link to="/why/what-you-provide">What you provide, what you get</Link></>,
      <><Link to="/why/deployment">Deployment options</Link> → <Link to="/why/how-it-compares">how it compares</Link></>,
    ],
  },
  {
    persona: 'Try it',
    question: '“How do I see the example running in my own AWS account?”',
    steps: [
      <><Link to="/tutorials/get-started">The online shop</Link> — what the example does</>,
      <><Link to="/tutorials/run-locally">Run it locally</Link> — no cloud account needed</>,
      <><Link to="/tutorials/deploy-to-aws">Deploy to your own AWS account</Link></>,
    ],
  },
  {
    persona: 'App developer',
    question: '“How do I create my own app from scratch?”',
    steps: [
      <><Link to="/app/get-started">Get started</Link> — AI-assisted or manual scaffold</>,
      <><Link to="/app/aggregate-vs-dcb-decision-guide">Model your domain</Link>, then write specs and scenarios</>,
      <><Link to="/infrastructure">Infrastructure</Link> — deploy and operate it</>,
    ],
  },
  {
    persona: 'Contributor',
    question: '“How does the framework work, and how do I extend it?”',
    steps: [
      <><Link to="/framework/contributing">Contributing setup</Link></>,
      <><Link to="/framework/internals/framework-internals">Framework internals</Link> (ordered)</>,
      <><Link to="/framework/internals/component-structure-pattern">Component-structure pattern</Link> → <Link to="/framework/internals/extending-the-framework">extending the framework</Link></>,
    ],
  },
];

function ReadingPathsSection() {
  return (
    <section className="margin-vert--lg">
      <div className="container">
        <Heading as="h2" className="text--center">
          Pick your path
        </Heading>
        <div className="row">
          {ReadingPaths.map((path, idx) => (
            <div key={idx} className="col col--3 margin-vert--md">
              <div className="card padding--md" style={{height: '100%'}}>
                <Heading as="h3">{path.persona}</Heading>
                <p><em>{path.question}</em></p>
                <ol>
                  {path.steps.map((step, i) => (
                    <li key={i}>{step}</li>
                  ))}
                </ol>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  return (
    <Layout
      title="The spec-driven event platform"
      description="Reventless is a type-safe, event-sourced CQRS platform for serverless applications. Define your domain as a spec in ReScript and derive database schemas, GraphQL and MCP APIs, and AWS infrastructure — production-ready and AI-native.">
      <HomepageHeader />
      <main>
        <HomepageFeatures />
        <ReadingPathsSection />
      </main>
    </Layout>
  );
}
