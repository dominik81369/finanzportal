import type { Metadata } from 'next';
import { GeistMono } from 'geist/font/mono';
import { GeistSans } from 'geist/font/sans';
import type { ReactNode } from 'react';

import './globals.css';

export const metadata: Metadata = {
  title: {
    default: 'Finanzportal',
    template: '%s · Finanzportal',
  },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html
      lang="de"
      className={`${GeistSans.variable} ${GeistMono.variable} font-sans antialiased`}
    >
      <body>{children}</body>
    </html>
  );
}
