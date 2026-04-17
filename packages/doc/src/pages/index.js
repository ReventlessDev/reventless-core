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
          Build scalable, event-driven business applications with a focus on domain logic.
          Ship fast with type-safe ReScript and infrastructure-as-code powered by Pulumi.
        </p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/app/get-started">
            Get Started
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="https://gitlab.com/reventless/reventless-universe">
            GitLab
          </Link>
        </div>
      </div>
    </header>
  );
}

export default function Home() {
  return (
    <Layout
      title="Event-Sourced CQRS for Serverless"
      description="Reventless is an event-sourced CQRS framework for building serverless business applications with ReScript and Pulumi">
      <HomepageHeader />
      <main>
        <HomepageFeatures />
        <HomepagePackages />
      </main>
    </Layout>
  );
}
