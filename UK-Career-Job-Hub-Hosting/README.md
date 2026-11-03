# Free HTTPS Deployment

This package is prepared for a public Node.js web service with no app password. It has not been published automatically. A hosting account you control and a source repository are still required.

## Deploy On Render

1. Extract the hosting ZIP into its own folder. Upload only those extracted files to a new GitHub repository intended for this app. Do not upload the entire Personal folder, credentials, browser data or node_modules.
2. Sign in to https://dashboard.render.com using your own account. Keep sign-in details out of chat. Review the current Free plan availability and limits in your dashboard before continuing; provider terms can change.
3. Choose New > Blueprint and connect that repository. The root render.yaml describes a Node web service named uk-career-job-hub with plan free. Keep the Root Directory blank. Confirm the plan is Free before deploying. Do not select a paid instance if Free is unavailable.
4. The build command is npm ci --prefix job_hub_backend and the start command is node job_hub_backend/server.cjs. The health path is /healthz. The app uses Render's PORT and RENDER_EXTERNAL_URL environment variables. No app login or password is configured.
5. After Render reports a successful deployment, open the exact HTTPS URL shown by the dashboard. Verify the page and a keyword search. Share that actual URL with other devices. It does not depend on your PC remaining on.

If the Blueprint option is unavailable, create a Web Service from the same repository with those build/start commands, Node runtime, health path and Free instance type. Use Node 22. If RENDER_EXTERNAL_URL is not supplied, set PUBLIC_ORIGIN to the exact HTTPS origin shown for the service, then restart it.

The root render.yaml uses JSON notation, which is valid YAML. It belongs at the repository root beside job_hub.html and the job_hub_backend folder. A static-site service or GitHub Pages alone cannot run this backend.

## Limits And Expectations

- Free services may sleep when idle, take time to start, impose bandwidth/compute quotas, or suspend service. Free hosting is not an always-on availability guarantee. Current terms must be checked with the provider; they could not be verified from this corporate network.
- The app has no password. Anyone with the URL can use it. It allows one live search at a time in hosted mode and at most ten search starts per minute for the whole instance. Others receive a busy message and can retry. These limits prevent simple overload, not every form of abuse.
- Two company portals are processed concurrently in hosted mode to reduce memory use. Broader multi-keyword searches can take several minutes. Streaming heartbeat messages keep the connection active while portals are checked.
- Career portals can block cloud-hosted requests even when they work from your PC. No deployment can guarantee every current vacancy. Partial and unavailable coverage remain visible.
- Settings and saved results stay in each browser's local storage. The new HTTPS URL starts with the default 39 companies; your locally added companies, including Expleo, are not automatically transferred. Add them on the hosted page as needed. Devices do not synchronize their settings.
- No browser session data, API keys or passwords are included in this source package. Review all portal URLs before making the repository public. Use a private repository if available for your hosting account and desired workflow.
- For a custom domain later, set PUBLIC_ORIGIN to that exact HTTPS origin. Unrelated Host and Origin values are deliberately rejected. Do not disable private-network URL restrictions to fix a blocked portal.

## Local Verification

From the extracted job_hub_backend folder:

```powershell
npm.cmd ci
npm.cmd test
npm.cmd start
```

Local startup stays bound to 127.0.0.1. Public binding is enabled only with a configured HTTPS origin. There are no Git commands or account changes in the package preparation step.