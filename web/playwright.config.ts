import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./tests",
  workers: 1,
  use: { baseURL: "http://localhost:3100" },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] } },
    { name: "mobile", use: { ...devices["iPhone 13"], defaultBrowserType: "chromium" } },
  ],
  webServer: {
    command: "npm run build && npm run start -- --port 3100",
    url: "http://localhost:3100",
    env: { API_BASE_URL: "http://127.0.0.1:8765" },
    reuseExistingServer: false,
  },
});
