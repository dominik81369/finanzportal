import type { NextConfig } from 'next';
import createNextIntlPlugin from 'next-intl/plugin';

const withNextIntl = createNextIntlPlugin('./i18n/request.ts');

const nextConfig: NextConfig = {
  experimental: {
    // CSV-/Excel-Import: bis zu 5.000 normalisierte Buchungen je Server Action
    // (lib/actions/import-transactions.ts); Standard wäre 1 MB, Vercel begrenzt
    // Request-Bodies auf 4,5 MB.
    serverActions: { bodySizeLimit: '4mb' },
  },
};

export default withNextIntl(nextConfig);
