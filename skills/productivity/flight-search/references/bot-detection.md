# Bot Detection & Mitigation for Flight Search Sites

Common anti‑bot mechanisms encountered on flight aggregators:

## 1. Consent / Cookie Walls
- **Where**: Google Flights, Skyscanner, Kayak (EU/UK visitors).
- **Appearance**: Banner with “Accept all”, “Reject all”, “More options”.
- **Fix**: Click the appropriate button (usually “Accept all”) to proceed. In headless browsers, accept all cookies via JavaScript or by setting cookies manually.
- **Session Insight**: In automated browser sessions, consent banners may persist or reappear if not handled correctly. Ensure the click action is properly executed and wait for the banner to disappear before proceeding.

## 2. CAPTCHA / “Are you a robot?” Pages
- **Where**: Kiwi.com, Momondo, Expedia, Skyscanner (under high traffic).
- **Appearance**: Image/text challenge, slider, or “Press and hold” verification.
- **Fix**: Solve manually. In automated flows, pause and prompt the user to complete the challenge, then resume.
- **Session Insight**: Some sites (like Skyscanner) may present sophisticated bot challenges that are difficult to automate. Be prepared to manually intervene or switch to a different site.

## 3. Rate‑Limiting / Temporary Blocks
- **Where**: Frequent rapid requests from same IP.
- **Appearance**: HTTP 429, “Too many requests”, or a generic error page.
- **Fix**: Introduce delays (2‑5 s) between requests, rotate user‑agents, or use residential proxies if heavy automation is required.
- **Session Insight**: Sites like Momondo and Cheapoair may employ aggressive blocking that presents as "Access Denied" pages rather than traditional rate limits. When encountering such blocks, immediately switch to an alternative site.

## 4. JavaScript‑Heavy Pages Requiring Interaction
- **Where**: Some sites load flight results via AJAX after a button click.
- **Appearance**: Empty results until a “Search” button is pressed.
- **Fix**: Ensure the script triggers the same UI events (click, keypress) that a real user would.
- **Session Insight**: Kiwi.com proved relatively cooperative for form interaction via browser automation, allowing successful search submission and results retrieval.

## 5. Site-Specific Behaviors (Based on Practical Experience)
- **Google Flights**: Requires explicit consent handling; after acceptance, generally cooperative with automation.
- **Skyscanner**: Prone to intermittent CAPTCHA challenges; consider having a manual solve fallback.
- **Momondo/CheapOAir**: Often employ aggressive bot detection resulting in complete access denial; lower priority for automation attempts.
- **Kiwi.com**: Generally more amenable to form interaction and search automation via browser tools.

## General Tips
- Use **incognito/private** windows to avoid cookie‑based price inflation.
- Keep a **stable user‑agent** string that matches a common desktop browser.
- If one site blocks automation attempts, immediately try another—don’t persist with a single site that’s actively blocking.
- When building scrapers, consider using the site’s **public API** (e.g., Skyscanner API, Google Flights API via unofficial endpoints) instead of HTML scraping.
- Always respect the site’s **terms of service** and **robots.txt**; for heavy usage, seek an official partnership or data feed.