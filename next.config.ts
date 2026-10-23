import type {NextConfig} from 'next';

const nextConfig: NextConfig = {
  // The UI is an internal tool served on 127.0.0.1; no telemetry-style headers.
  poweredByHeader: false,
  reactStrictMode: true,
};

export default nextConfig;
