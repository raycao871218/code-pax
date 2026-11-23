# Code Pax concept implementation QA

final result: passed

## Target and scope

Selected concept: `work/ui-redesign/concept-reference.png`.
Existing native SwiftUI application; this is an implementation in the production app, not a web prototype.
DeepSeek is excluded at the user's request. Existing CLI agents and configuration remain available.

## Evidence

- Landscape application viewport: `work/ui-redesign/concept-app-light.png`.
- Full simulator capture including its letterboxed landscape preview: `work/ui-redesign/concept-screen-light.png`.
- Final portrait/dark capture: `work/ui-redesign/concept-portrait-dark.png`.
- The landscape preview used a separate unsigned simulator app copy constrained to landscape. Only the actual app rectangle was extracted for comparison; no UI was painted, stretched, or replaced. Production Info.plist retains all existing iPad orientations.
- 66 iOS simulator tests passed, including full-screen and embedded terminal automatic focus, message ordering/grouping, retries, drafts, and attachment behaviors.
- Device build 41 passed signing verification. Installation and remote-server operation are separate validation boundaries.

## Fidelity review

| Surface | Result |
| --- | --- |
| Typography | Native system fonts and SF Symbols match the source's intended Apple typography; small metadata stays secondary. |
| Structure | Narrow project sidebar, three vertical navigation entries, bottom server/settings controls, breadcrumb header, Agent selector, and chat/terminal controls implemented. |
| Spacing | Compact header and single-row composer; conversation centered with a maximum reading width. Duplicate system navigation bars were removed. |
| Colors | Neutral canvas/sidebar, subtle selection fills, restrained accent for actions; dark mode checked separately. |
| Assets | Concept contains standard UI icons only. SF Symbols are used; no raster artwork or fake screenshots replace functional UI. |
| Message treatment | User bubble on the right, assistant identity above the reply, execution details collapsed beneath the reply. Delivery errors and retries remain visible when actionable. |
| Composer | Attachment control, native multiline input, model menu, and send/stop action. Permissions, reasoning effort, and usage remain accessible in the model menu. |
| Agent selection | Native popover with a selected row and management link. Choosing a different Agent starts the explicit new-session flow; existing sessions are not converted. |
| Responsive layout | Actual portrait simulator capture checked; compact model controls preserve input width. Sidebar can be shown/hidden from the custom header. |

## Expected differences and follow-up polish

- P3: iPadOS owns popover corner radius, material, shadow, safe areas, and window chrome; they intentionally retain native rendering.
- P3: Agent choices reflect supported tools rather than the concept's illustrative list. DeepSeek is absent.
- Preview is disconnected, so it shows a connection notice and a disabled send action instead of inventing a successful connection.
- Execution summaries reflect real event counts, not the concept's illustrative “3 files”.
- No P0/P1/P2 visual issues remain in the reviewed captures. This does not certify remote CLI execution or every device/font-size combination.

## Implementation checklist

- [x] Sidebar and functional navigation
- [x] Agent chooser and configuration route
- [x] Embedded SSH terminal and return to chat
- [x] Native input, attachments, model/permission controls, send/stop
- [x] Retry, approval, history, archive, and unread entry points retained
- [x] Source/capture comparison and dark/portrait review
- [x] Native tests and signed device build

## Home screen implementation — Build 42

final result: passed

Reference: `work/ui-redesign/home-reference.png`.
Compared directly with `work/ui-redesign/home-implemented-light.png` (actual landscape app viewport, extracted from `home-screen-landscape.png` without restyling). Portrait layout checked in `home-portrait-light.png`; the empty state and dark appearance checked in `home-empty-dark.png`.

- Typography: native system title/body/monospaced endpoint text; hierarchy follows the selected concept.
- Layout: restrained brand/settings header, centered content column, single server list, explicit connect and management actions, small help entry and footer.
- Tokens: neutral background and dividers, understated selected row, one primary accent button. Secondary connection buttons use an outline.
- Icons/assets: standard SF Symbols; the concept needs no bespoke raster assets. No screenshot is used as interactive UI.
- Copy: server names and example endpoints match the reference fixtures. Actual application rows use saved profiles and real SSH connection state.
- Behavior: existing password prompt, host identity confirmation, keychain preference, editing, deletion confirmation, disconnect and workspace return routes preserved. The empty state opens the same server editor through the add action.
- Responsive behavior: `ViewThatFits` allows server actions to wrap below the identity on narrower layouts; no persistent control is intentionally hidden.
- Expected P3 differences: exact font metrics, device aspect ratio, system safe areas, and native button/gear icon rendering.
- Validation: 66 simulator tests passed; signed device build and installation succeeded. Real remote-server login was not exercised during this visual change.
- No P0/P1/P2 visual issues remain in the reviewed captures.

## Claude chat and pixel avatar — Build 43 (2026-11-23)

- Native Claude chat now has its own bridge route, persisted Claude session ID, stream reconciliation, tool results, approval/question responses, interruption and history pagination. Codex process events and writer probes do not modify Claude sessions.
- Claude launch configuration is attached at send time from the device keychain, avoiding credentials in the pending-send/outbox UserDefaults records. Accepted operation retries do not launch another process when credentials change.
- Avatar is a native pixel rendition of the orange Clawd silhouette, with separate leg/eye poses. Only the newest reply animates; reduced motion and inactive scenes pause it. Existing Codex artwork remains available.
- Simulator evidence: `work/ui-redesign/claude/chat-light.png`, `chat-dark-a.png`, `chat-dark-b.png`. Consecutive dark captures have different pixels inside the avatar rectangle, confirming actual rendered pose changes. Preview data is disconnected and is not evidence of a real remote model response.
- 118 backend tests passed, including a subprocess fixture using the bidirectional CLI protocol, approval allow/deny/cancel, question validation, stop, failure, deduplication, restart/resume, no-Codex operation and history pagination.
- 67 iOS tests passed. Final simulator and signed physical-device builds succeeded; codesign and IPA archive validation passed. Packaged Claude adapter matches the source file.
- Installed local Claude Code 2.1.163 accepted the initialization handshake. Local auth status is logged out; model responses, real account tool approval and remote-server integration remain unverified.
- Physical installation was attempted but rejected because the paired iPad was locked and the developer image could not mount. Build 43 IPA is ready at `work/CodePax-0.17.0-build43-development.ipa`; do not claim installation succeeded.

### Build 43 installation follow-up

After the user unlocked the iPad, `devicectl device install app` succeeded for `com.raycao.codexipad`, followed by a successful process launch. This supersedes the locked-device installation limitation above. Remote Claude login/model/tool behavior still needs real-server validation.

## Build 44 — provider selection follow-up

- Device preferences showed Claude saved in terminal mode. A read-only SSH status probe confirmed the selected server still ran bridge 0.16.1 without `claudeChat`; snapshot showed one running Claude terminal, the previously identified Claude terminal.
- Removed capability-dependent terminal fallback and the terminal-to-chat Codex substitution. Claude chat intent now remains Claude chat; unsupported backends show an explicit update action and block creation. Creation always includes provider/mode, validates pending request identity and checks the returned session identity.
- 70 iOS tests passed, including old-backend Claude selection, terminal-to-chat provider retention and mismatched pending requests. Signed Build 44 installed successfully on the physical iPad; IPA passed integrity validation.
- Uploaded and compiled the four current backend scripts via the existing trusted SSH host. `ensure` returned running version 0.16.1 with `upgradePending=true`, preserving the active terminal. Asked the user whether to end that exact terminal before restarting. No existing server task was stopped without an answer.

### Server upgrade and live Claude validation

The user explicitly approved ending the previously identified Claude terminal. Stopped only that matching active Claude terminal, then ran the existing safe upgrade path. Status now reports bridge 0.17.0, `claudeChat=true`, and no pending upgrade.

Created a separate Claude chat connectivity-check session on that server and sent two English-only messages, following the user's language preference. Both turns completed without errors; the second turn recalled the exact marker requested in the first, verifying CLI resume/context persistence. Snapshot confirmed `agent=claude` and `mode=chat` for both turns. Archived the test session after completion. This verifies real server Claude execution and context restoration; it does not substitute for observing the user's complete iPad UI flow.

## Build 45 — Claude model versions and effort

- Removed the hardcoded three-alias picker. The bridge queries Claude's initialize control response without submitting a model prompt, normalizes concrete `resolvedModel` IDs, preserves aliases for existing sessions, deduplicates the Default row and advertises only each model's reported effort levels.
- Native Claude/Codex catalogs remain separate. Claude selections include a concrete version; effort is validated server-side, passed through `--effort` and persisted on the session. Unsupported levels are rejected before a user message/process turn is accepted. Default effort omits the CLI flag.
- Server upgraded safely to bridge 0.17.2 (`claudeModels=true`). The actual server returned 13 concrete models. An English-only live check using `claude-sonnet-5-5` with `high` completed successfully and returned the requested marker; snapshot confirmed the selected model and effort. The probe session was archived after completion.
- 121 backend tests and 71 iOS tests passed. Model-probe tests verify no conversation turn is started, metadata is configuration-scoped, legacy Codex metadata still decodes and selected effort reaches the CLI argv.
- Signed Build 45 installed successfully on the physical iPad. Simulator capture `work/ui-redesign/claude/models-build45.png` shows the concrete model/effort composer label; its conversation is a disconnected preview, not a live server transcript. IPA integrity and code-signature checks passed.

## Build 46 — Chinese / English interface

- Added persistent Follow system / Simplified Chinese / English language selection in home settings, workspace settings and appearance settings. Locale changes propagate through the existing view hierarchy without an identity reset.
- Added native Localizable and InfoPlist string catalogs. English translations cover 583 app-owned keys; compiler-extracted Chinese UI keys have no untranslated entries, and placeholder signatures were validated. Dynamic statuses and activity counts use app-owned localization; user titles, paths, command output and conversation content remain verbatim.
- System mode uses the first supported language in the user's language preferences and falls back to English. Explicit language choices override that selection immediately. Local network permission text has English and Chinese resources.
- 75 iOS tests passed, including a live hosting-window locale switch with an unchanged state UUID, preference fallback, compiled-resource lookup, interpolation/data preservation and translated activity counts.
- Reviewed actual simulator captures: `work/ui-redesign/home-english-build46.png`, `workspace-english-build46.png`, `home-chinese-build46.png`. English controls and Chinese return render without clipped buttons; Chinese example server/chat names and chat text remain unchanged by design. Previews do not connect to the server.
- Signed Build 46 installed successfully on the paired physical iPad. The development IPA is `work/CodePax-0.18.0-build46-development.ipa`; codesign and archive checks passed. No server processes or Agent language preferences were changed for this UI-only task.
