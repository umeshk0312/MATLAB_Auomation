# UK Career Job Board Search Hub

## Run

Requires Node.js 20.8 or newer. From this folder:

```powershell
npm.cmd install
npm.cmd start
```

Open the localhost URL printed by the server, not the HTML file directly.
The first available port from 8765 through 8775 is used. Stop with Ctrl+C.

## Share Through HTTPS

See [DEPLOY.md](DEPLOY.md) for the free-hosting setup and limitations. Run prepare-hosting.ps1 to create an isolated source ZIP under hosting-output. It does not publish the app. A hosting account and deployment approval are still required. No app password is required.

## Companies, Keywords And Previous Sessions

Use Manage Companies to add a company name and its public HTTPS career URL. Every searched keyword is automatically added to Quick Keywords; there is no separate keyword-entry field. Remove companies with the trash button in the portal table, and remove keywords with their adjacent X button. Duplicate company names and URLs are rejected. Up to 100 companies and the 50 most recently searched unique quick keywords are retained. Searching an existing keyword does not create another copy.

Search multiple keywords using commas: `Matlab, Simulink` and `Matlab,simulink` mean the same thing. Each entry is searched separately and results matching ANY entry are merged, with duplicate job URLs removed. Within an entry such as `embedded software`, all words are required for locally extracted matches. Empty entries are ignored, and duplicates are collapsed without regard to case. Search up to 10 distinct entries within the 120-character input limit.

Company and keyword lists, the current query, expanded sections and previous search results are saved automatically in this browser's local storage. Return using the same browser profile and localhost URL (including its port). Clearing browser data or using a different browser or port does not retain the session. Storage errors are displayed on the page.

Previous results are marked as saved and not refreshed; reopening the page does not automatically contact the portals. Up to 1,000 results are retained. Interrupted searches are marked incomplete. A new search refreshes the data. Clear search clears the query and saved results but keeps company and keyword lists. Changing the company list cancels the active search and clears outdated results.

The UK name is the hub's title, not a country filter; your saved portal locations are unchanged.

## Coverage

- The app starts with the 39 portals in the adjacent HTML file. Searches attempt the currently configured company list, including additions and excluding removals.
- Keywords are matched against accessible job titles and descriptions, not company names.
- The broader crawler applies automatically to existing and future company entries; it is not an Expleo-specific setting.
- Workday uses its live search endpoint, retaining saved filters and retrieving up to 500 results.
- Other sites use accessible JobPosting metadata or recognizable job descriptions. Up to eight listing pages and 100 linked job descriptions per keyword are inspected. Title matches are prioritized, but description-only matches are also checked. Page data is reused across keywords within one company search.
- Accessible next-page links, pagination controls, same-site career frames and links to recognized public ATS boards are followed. GET forms and keyword URL fields are recognized case-insensitively, including searchKeyword. Existing location parameters are retained. Undiscovered pagination, JavaScript-only listings and custom APIs are not fully covered.
- Each company also has a Search indexed listings link, scoped to its portal hostname and current keywords. This opens an external Google search only when clicked; it is a manual fallback, not an automatically retrieved or verified vacancy feed. Indexed results may be stale, irrelevant or outside saved portal location filters.
- Partial coverage is always reported for these generic connectors, including when no matches are retrieved. It is not proof that no matching vacancies exist.
- Blocked, login-only, unavailable and timed-out sites cannot be fully checked. No login, CAPTCHA bypass or third-party search proxy is used.
- Original saved URLs are retained. Old links, registration pages and individual job links may not lead to a current vacancy list.
- Matches are live retrievals, not a guarantee that a vacancy is still accepting applications. Known expired structured postings are excluded. Verify availability on the official posting.
- Existing location filters remain where supported; an unfiltered portal may return worldwide jobs.

## Privacy And Limits

By default the server binds only to 127.0.0.1. With PUBLIC_ORIGIN or Render's RENDER_EXTERNAL_URL set to its HTTPS origin, it binds to 0.0.0.0 on PORT and accepts only that public host/origin. Your keyword is sent to the company sites that support search; requests originate from the computer or hosting instance running the backend. Settings and saved result snapshots remain in browser local storage, not a server database. Do not put credentials in portal URLs. Private network addresses, credential-bearing URLs, custom ports and redirects to non-public destinations are rejected.

Six portals are checked concurrently. Keywords are queried sequentially within each portal, with up to four job-page reads in parallel. The portal time budget is 60 seconds for one keyword, 120 seconds for two, and at most 180 seconds for three or more; each individual request has a 10-second limit. Page counts, request failures and reached limits are reported. If a page or keyword fails, earlier successful matches are retained and coverage is marked partial. Stop or a new search cancels the previous search. Results stream as sources finish. More extensive searches may take several minutes.

Hosted mode reduces concurrent portals to two and permits one active search at a time. Local mode permits two active searches. Both have an instance-wide limit of ten search starts per minute. Page caching is limited to 8 MB per company search. A 429 response means the service is busy, not that no vacancies exist. /healthz is a lightweight health probe.

## Tests

```powershell
npm.cmd test
```

Tests use local fixtures except the localhost HTTP server test; external site availability is not part of the regression suite.