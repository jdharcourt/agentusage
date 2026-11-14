# AgentUsage

A small native macOS menu bar app for Codex. It automatically detects your existing Codex account and data location. Click the terminal icon to see remaining plan allowance, running agents, token usage, and estimated API value. No folder selection or separate sign-in.

Inspired by [Vorssaint](https://vorssaint.com/)'s local AI usage monitoring. Built independently with SwiftUI and AppKit, with no third-party dependencies.

## Run

Requires macOS 14 or later, an installed and signed-in Codex app or CLI, and Xcode 16 or later with Swift 6 to build.

```sh
git clone https://github.com/jdharcourt/agentusage.git
cd agentusage
make run
```

The app appears in the menu bar, with no Dock icon. To keep it, drag `dist/AgentUsage.app` to Applications. Launch at login is available in Settings after installing the app.

`make build` produces an ad-hoc signed app and ZIP in `dist`. Downloaded builds are not notarized; building locally is the recommended installation method. The build targets the Mac's current architecture.

## What it shows

| View | Contents |
| --- | --- |
| Overview | Recorded plan limits and reset times, today's tokens and API value, cached input, running agents, current session |
| Agents | Tasks observed running, their project, model and token count, recent sessions |
| History | Account-wide lifetime tokens, peak daily usage and streaks, plus local lifetime tokens, estimated API value, and tokens by model |

Choose remaining usage, running agents, today's tokens, or today's API value for the menu bar label. Local history refreshes every five seconds; account details refresh every minute and on manual refresh.

## Data and accuracy

AgentUsage discovers Codex in the Codex app, common CLI install locations, PATH, and the official VS Code extension. It connects to [Codex's app server](https://learn.chatgpt.com/docs/app-server#auth-endpoints) over stdio to read the current account, live rate limits, and account usage summary. The server reports its data location automatically, including custom `CODEX_HOME` locations. AgentUsage reads `sessions` and `archived_sessions` there for detailed local accounting.

- **Account detection** uses your existing Codex sign-in. It shows the signed-in email, plan, and workspace when available. No credentials are entered into AgentUsage. If Codex is signed out or missing, the app explains what to do and retries automatically.
- **Remaining usage** comes from the authenticated `account/rateLimits/read` response, with actual window duration, reset time, credits and observation time. Recorded local limits are a fallback when no live account connection is available. Expired readings are not assumed to represent a new allowance. API-key accounts do not expose ChatGPT plan limits.
- **Running agents** are inferred from local task start/completion/abort events. An open task without activity for ten minutes is marked unconfirmed. This is not a process-level guarantee: crashed clients and long silent tasks can look alike.
- **API value** is a USD estimate using bundled standard token prices, including discounted cached input. It is not your API bill or the cost of your ChatGPT subscription. Fast tiers, long-context surcharges, regional pricing, tools, and historical price changes are not included. Cache writes use the listed 30-minute rate. Unknown models are clearly marked unpriced and excluded from the estimate.
- **Account lifetime** comes directly from `account/usage/read`, along with peak daily tokens and usage streaks when supported. Unavailable metrics stay unavailable, rather than showing zero. The account connection does not expose lifetime billed API spend.
- **Lifetime on this Mac** means available logs, including archived sessions. This section's cost estimate covers those logs, independently of the account-wide token summary. Deleted logs and other devices cannot be reconstructed locally. Initial cumulative records are assigned to their observation date. Repeated cumulative totals and copied inherited events are deduplicated. Counter resets are handled without discarding earlier usage.
- **Tokens** include input and output; cached input is a subset of input. Reasoning tokens are already included in output and are not added a second time.

Bundled prices are in [prices.json](Sources/AgentUsageCore/Resources/prices.json), checked against [OpenAI's published pricing](https://developers.openai.com/api/docs/pricing) on 14 November 2026. Only models with a verified bundled rate are priced.

## Privacy

No separate sign-in, API key entry, analytics, or third-party Swift dependencies. Codex handles its own credentials and authenticated requests to OpenAI. AgentUsage never reads, copies, logs, or exports authentication tokens. It does not start model turns or make inference requests. Its app-server connection uses stdio and disables Codex analytics for that process.

Your account identity and usage metadata stay in memory. Conversation content is not retained or transmitted by AgentUsage. Preferences store only the menu bar display choice; launch-at-login registration is handled by macOS. Nothing from your Codex history or account is included in builds or uploaded to this repository.

The app opens session logs read-only, skips symlinked log files, bounds individual record sizes, and reads only appended bytes after the initial scan. Restarting rebuilds its in-memory history. Oversized or malformed relevant records are skipped and reported in the panel.

## Development

```sh
make test
make build
.build/release/AgentUsage --diagnose
.build/release/AgentUsage --diagnose-account
```

`--diagnose` prints local aggregate counts and costs. `--diagnose-account` verifies automatic account detection and prints account type, plan, lifetime tokens, and limit-window count. Neither prints credentials, email addresses, conversation text, or file paths. The test suite covers account response parsing, unavailable metrics, signed-out and API-key accounts, cumulative accounting, inherited history, append-only reads, incomplete records, model changes, counter resets, stale tasks, limits, deleted/truncated files, malformed records, credential isolation, and cache pricing.

The GitHub Actions workflow tests and packages the macOS app. Build artifacts contain only the app bundle.
