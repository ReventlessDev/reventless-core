import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import HomepageFeatures from '@site/src/components/HomepageFeatures';
import HomepagePackages from '@site/src/components/HomepagePackages';

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
          Event-Sourced CQRS Framework for Serverless
        </p>
        <p className={styles.heroDescription}>
          Describe your domain as commands, events, and projections in type-safe
          ReScript. Reventless provisions and wires the serverless infrastructure —
          queues, tables, functions, event routing, and a GraphQL API — so you
          focus on business logic, not plumbing.
        </p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/tutorials/get-started">
            Try the example
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/app/get-started">
            Build an app
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/framework/get-started">
            Contribute
          </Link>
        </div>
      </div>
    </header>
  );
}

const ReadingPaths = [
  {
    persona: 'Evaluator',
    question: '“What is Reventless? Should I use it?”',
    steps: [
      <><Link to="/app/">Introduction</Link> — what, why, who</>,
      <><Link to="/tutorials/get-started">Tutorial overview</Link></>,
      <><Link to="/tutorials/hybrid-based">Hybrid walkthrough</Link></>,
    ],
  },
  {
    persona: 'App developer',
    question: '“I want to build something with Reventless.”',
    steps: [
      <>The <Link to="/tutorials/get-started">Tutorial spine</Link> — understand, run locally, deploy, test</>,
      <><Link to="/app/get-started">App Guide</Link> — build your own plugins</>,
      <><Link to="/infrastructure">Infrastructure</Link> — deploy to your own domain</>,
    ],
  },
  {
    persona: 'Contributor',
    question: '“I want to contribute to the framework.”',
    steps: [
      <><Link to="/framework/get-started">Contributing get-started</Link></>,
      <>Framework internals (ordered)</>,
      <>Component-structure pattern → extending the framework</>,
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
            <div key={idx} className="col col--4 margin-vert--md">
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
      title="Event-Sourced CQRS for Serverless"
      description="Reventless is an event-sourced CQRS framework for building serverless business applications with ReScript and Pulumi">
      <HomepageHeader />
      <main>
        <ReadingPathsSection />
        <HomepageFeatures />
        <HomepagePackages />
      </main>
    </Layout>
  );
}
