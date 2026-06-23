import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import Lockup from '@site/static/img/logo-lockup-v16e-log-asym.svg';
import styles from './styles.module.css';

// Custom Logo: the V16e horizontal lockup (icon + wordmark, no tagline).
// The lockup is inlined as SVG (not an <img>) so the wordmark's <text> picks up
// page-loaded fonts and the fading deck tail under the wordmark renders crisply.
// A single themed SVG is used (the "R"/"less" wordmark is fill="currentColor")
// rather than separate light/dark files toggled by display: inlining two SVGs
// makes SVGO collapse both gradient ids to the same value, so the hidden one's
// id wins and the visible deck tail loses its gradient in dark mode. With one
// SVG the gradient id is unambiguous and only the text colour switches per theme.
export default function Logo(props) {
  // The navbar passes imageClassName / titleClassName for the default <img>
  // markup; we render our own, so drop them and keep the rest (className, etc.).
  const {imageClassName, titleClassName, className, ...rest} = props;
  const homeUrl = useBaseUrl('/');
  return (
    <Link
      to={homeUrl}
      className={clsx(className, styles.brand)}
      aria-label="Reventless"
      {...rest}>
      <Lockup className={styles.lockup} aria-hidden="true" />
    </Link>
  );
}
