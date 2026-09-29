import { PlaceholderSection, placeholderMetadata } from './placeholder-section';

export const generateMetadata = placeholderMetadata('overview');

export default function OverviewPage() {
  return <PlaceholderSection section="overview" />;
}
