import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

const title = "Itinera — A field guide for the trip you actually take";
const description =
  "Plan paced, day-by-day city itineraries around your stay, keep your next move close, and adapt when the day changes.";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = (
    requestHeaders.get("x-forwarded-host") ??
    requestHeaders.get("host") ??
    "localhost:3000"
  ).split(",")[0].trim();
  const forwardedProtocol = requestHeaders
    .get("x-forwarded-proto")
    ?.split(",")[0]
    .trim();
  const protocol = forwardedProtocol === "https" ? "https" : "http";

  let origin: URL;
  try {
    origin = new URL(`${protocol}://${host}`);
  } catch {
    origin = new URL("http://localhost:3000");
  }

  const socialImage = new URL("/og.png", origin).toString();

  return {
    metadataBase: origin,
    title,
    description,
    alternates: { canonical: "/" },
    icons: {
      icon: "/app-icon.png",
      apple: "/app-icon.png",
    },
    openGraph: {
      type: "website",
      title,
      description,
      siteName: "Itinera",
      url: "/",
      images: [{ url: socialImage, width: 1200, height: 630, alt: title }],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [socialImage],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
