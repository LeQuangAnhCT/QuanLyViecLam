# Browser startup probes

These function files are diagnostic probes for Chrome DevTools `evaluate_script`, not production entry points. Run them on a separate browser profile with the local Vite server running. They replace repository/auth methods in memory and restore them afterward; they do not sign in, persist sessions, or write database data.

- `startup-probe.js` checks that a STAFF calendar can finish initial loading while the optional job-profile request is still pending. The role must already be resolved correctly. Before the startup fix, the result is `SLOW`; after the fix, it is `PASS`.
- `session-probe.js` checks that a newer sign-in event survives an older `getSession` response, repeat clicks start one OAuth request, and unmount removes the listener.

With Chrome DevTools CLI installed, first open `http://localhost:5173` and find its page ID using `chrome-devtools list_pages`. Then run from PowerShell in the project directory, replacing `PAGE_ID`:

```powershell
$probe = Get-Content -Raw -LiteralPath 'tests/performance/startup-probe.js'
chrome-devtools evaluate_script $probe --pageId PAGE_ID --waitForStableDom false
```

For rendering measurements, use the same CPU/network settings for both traces. The recorded local comparison used 4× CPU throttling and no network throttling. Synthetic API delays measure a dependency on optional data, not the duration of the real Google OAuth flow.

For a visual check with slow optional data, open `/tests/role.html?role=staff&startupDelay=8000`. The calendar should appear while the job profile and notifications are still loading. The community/profile form should show its loading state instead of allowing an existing job profile to be overwritten. The first notification snapshot should populate the unread count without replaying old toast messages.
