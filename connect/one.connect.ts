import { defineConnectApp } from "@withone/connect/config";

// Maia reads whatever the person grants. They can narrow this on One's
// page. They cannot widen it. Create or update the app with
// `one connect create` from this directory, then copy the client secret
// and connect key from that page into the repo .env.
export default defineConnectApp({
  name: "Maia",
  redirectUris: [
    "http://127.0.0.1:8090/one/callback",
    "http://localhost:8090/one/callback",
    "http://127.0.0.1:8788/api/one/callback",
  ],
  reason:
    "Maia reads the accounts you connect and keeps them in your memory on this machine.",
  ask: {
    gmail: { access: "read-only" },
    "google-calendar": { access: "read-only" },
    "google-docs": { access: "read-only" },
    github: { access: "read-only" },
    slack: { access: "read-only" },
    notion: { access: "read-only" },
    linear: { access: "read-only" },
    canva: { access: "read-only" },
    "one-drive": { access: "read-only" },
    discord: { access: "read-only" },
    stripe: { access: "read-only" },
  },
});
