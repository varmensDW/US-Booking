import type {Metadata} from 'next';
import {Inter, JetBrains_Mono} from 'next/font/google';
import 'flag-icons/css/flag-icons.min.css';
import './globals.css';
import {Providers} from './providers';

const inter = Inter({subsets: ['latin'], variable: '--font-inter', display: 'swap'});
const mono = JetBrains_Mono({subsets: ['latin'], variable: '--font-jetbrains', display: 'swap'});

export const metadata: Metadata = {
  title: 'US Booking · Order Review',
  description: 'US1 warehouse booking review dashboard',
};

export default function RootLayout({children}: {children: React.ReactNode}) {
  return (
    <html lang="en" className={`${inter.variable} ${mono.variable}`}>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
