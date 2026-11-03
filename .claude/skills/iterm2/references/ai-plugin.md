# AI: the plugin, the features, and the permission model

<https://iterm2.com/ai-plugin.html> and
<https://iterm2.com/documentation-ai-chat.html>

## The plugin, and why it is separate

iTerm2 3.5 moved generative AI **out of the app** into a separately signed
bundle. The reason is not packaging convenience — it is the whole privacy
design, stated on the plugin page:

> It provides necessary functionality for iTerm2 to make network requests. It
> exists as a separate component **to ensure that there's no way to
> accidentally send information from the terminal over the network**.

The terminal binary cannot make those requests. The plugin is the only thing
that can, and it is optional. Install it by unzipping into `/Applications`;
you never run it, iTerm2 finds it. 3.7's first-run wizard installs it for you,
together with the new **Companion** plugin (`com.googlecode.iterm2.iTermCompanion`,
the iPhone app's bridge; `references/session-status.md`), behind one password
prompt.

Read the guarantee narrowly: it is about terminal content reaching an AI
provider. The app itself still talks to iterm2.com — Sparkle updates, the
Python runtime and (3.7) the uv manifest, and an opt-in refresh of the
built-in model list.

Installed here (unchanged by the 3.7.6 update; the Companion plugin is not
installed):

```
/Applications/iTermAI.app             iTerm2 AI Plugin 1.1   (Homebrew cask: itermai)
/Applications/iTermBrowserPlugin.app  1.0
```

`iterm2-doctor` reports both on its `plugins:` line. They are advisory
entries in `manifest.txt` — a plugin the user chose not to install is not a
fact that stopped being true about iTerm2. Versions come off the bundle:

```bash
defaults read /Applications/iTermAI.app/Contents/Info CFBundleShortVersionString
```

## Turning it on

**Settings > General > AI** — a set of sections of its own, *not* part of the
Magic pane (a common mix-up; see `references/preferences.md`).

**AI > General**

| Setting | What the docs say |
| --- | --- |
| Plugin | "To use AI features you must install the AI plugin." |
| Consent | "You must consent to AI features before they can be used. This is a **secure user default which requires you to enter an administrator password to change**." |
| API Key | "users must provide their own API keys. Unlike most settings (which are saved in user defaults), the AI key is **stored in the keychain** to prevent unauthorized access." |
| Always use the recommended model from … | "automatically use the most current model from the selected provider. If disabled, click Configure AI Model Manually to tweak values yourself." |
| Timeout | "The maximum time to wait for a response to an AI query." Since 3.7.5 an **idle** timeout — the longest gap between bytes — defaulting to 20 minutes (30 s in 3.6.11, 5 min in 3.7.0). |

**AI > General > Configure AI Model Manually** — Model ("sent in the API
request"), Token Limit ("the maximum number of tokens in the context and in a
response. If this value is too high your requests may fail"), the endpoint
URL, API ("Which style API to use"), and Features:

```
Hosted File Search              OpenAI Responses API only
Hosted Web Search               OpenAI Responses API only
Code Interpreter                OpenAI Responses API only
File Upload and Vector Store    OpenAI Responses API only (vector store unused)
Function Calling                most APIs
Streaming Responses             most APIs
```

**AI > General > Prompts** — the prompts themselves are editable, with
`\( … )` substitution. `Edit > Engage Artificial Intelligence` uses
`ai.prompt`; the AI Chat prompts vary by which permissions are enabled. The
binary carries a family of them: "AI Prompt for AI Chat with Browser", "…with
no function calling", "…with ReadOnlyTerminal", "…with ReadOnlyTerminalBrowser".

### Which providers

**The documentation never says.** Grepping every official page, the only
provider named anywhere is OpenAI, and only as a feature-support qualifier —
even though the settings clearly have a provider popup. That is a real gap.

The binary and the 3.7 release notes answer it. First-class providers in
3.7.6: **OpenAI, Anthropic, Gemini, DeepSeek and Ollama** (Ollama since 3.7.5:
it lists local models and reads each one's context window and capabilities
from the server; the API type once called `Llama` is now `Ollama`). Endpoints
in the binary include `api.openai.com`, `api.anthropic.com`,
`generativelanguage.googleapis.com`, `api.deepseek.com` and `openrouter.ai`.
**Apple Intelligence** appears as an on-device option, used by default for
the AI command safety check. The manual model editor has presets for
OpenAI-compatible gateways (OpenRouter, z.ai, Qwen, MiniMax), a *Test
Connection* button, models served over plain HTTP on the LAN, and per-model
custom headers.

So a provider without a preset, or a local proxy, is configured by turning
off *Always use the recommended model from*, opening **Configure AI Model
Manually**, and setting Model / Token Limit / URL / API / Features by hand.

## The features

| Feature | Where |
| --- | --- |
| **AI Chat** | `Window > AI Chat`; `Session > Open AI Chat` links the current session to a new chat |
| **Explain Output** | `Edit > Explain Output with AI` — sends the selection or selected command, then **annotates the terminal in place** and opens the chat to drill down |
| **Engage Artificial Intelligence** | `Edit > Engage Artificial Intelligence` — turns the value at the cursor into a prompt. With shell integration and focus on the terminal, it uses what you have typed at the prompt so far |
| **Codecierge** | `View > Toolbelt > Codecierge` — "Set and achieve terminal goals ... guides you step-by-step based on your terminal activity" *(it2tip)*. Meant for multi-step tasks |
| **Composer suggestions** | Off by default; see the privacy note below |
| **Web Browser profiles** | Set Profile Type to Web Browser (`iTermBrowserPlugin.app`); AI can act in the page if permitted |

The Composer itself is not an AI feature — `⇧⌘.` opens a scratchpad for
editing a command before sending it, and **Auto Composer** (`View > Auto
Composer`) replaces the shell prompt with a native text control with syntax
highlighting and filename/command completion, including over SSH Integration.
It **requires shell integration**. AI only enters through one toggle.

## The permission model — the part worth understanding

A new chat starts with **no visibility into your windows at all**. You then
optionally *link* a session to it, and each capability is a **tri-state**,
rotated by clicking it in the chat's info menu:

```
Never  ->  Ask  ->  Always  ->  Never
```

A check mark is granted, a dash is "ask before using", neither means always
deny — "the AI agent will not be offered functions related to those
categories". So a denied capability is not merely refused at call time; the
function is never advertised to the model.

The categories, with what each actually exposes:

| Category | Exposes |
| --- | --- |
| Check Terminal State | current directory, shell, current/last command and its exit status, terminal size, the host you are SSHed to, current username |
| Run Commands | executes commands on your behalf |
| Control Terminal | sends keystrokes, and restarts the session (*Type for You* before 3.7) |
| View Contents | what the linked session holds, history included (*View History* before 3.7) |
| View Manpages | man pages — **including the remote host's, under SSH Integration** |
| Write to Clipboard | the pasteboard |
| Write to filesystem | files |
| Act in Web Browser | contents of the current page (browser profiles only) |
| Send Commands and Output Automatically | terminal contents streamed to AI continuously |

The same list appears as **Settings > General > AI > Features**, plus one
more, whose documentation is unusually candid and is the single most useful
privacy sentence on the site:

> **Offer AI command suggestion in Composer and Auto Composer** — "as you
> type in the composer what you have entered and relevant files or commands
> are sent to AI so it can make suggested completions. **This is disabled by
> default because it is not very privacy-friendly.**"

Corresponding strings in the binary: "AI can Check Terminal State", "AI can
Act in Web Browser", "AI Chats can view or control this session."

## Where the keys go — the part that matters here

The binary states it outright. In 3.6.11:

> Enter the API key for your AI provider. The key will be stored securely in
> the Keychain.

In 3.7.6, where the settings show one key per provider:

> Keys are stored securely in the macOS Keychain.

3.7 changed *how*, not *where*:

- **One key per provider**, as separate Keychain items named `OpenAI API Key
  for iTerm2`, `Anthropic API Key for iTerm2`, `Gemini …`, `DeepSeek …`,
  `Llama …`, `Apple Intelligence …`. "Claude is not sent a key saved for
  another AI service." A model's key choice is *Automatic*, the provider's
  key, a model-specific key, or none; since 3.7.6 *Automatic* sends a
  provider's key only to that provider's own servers (it could send an OpenAI
  key to an OpenRouter or Azure gateway before).
- **An entitlement-scoped Keychain group** (the data-protection keychain),
  migrated from the login keychain with one extra prompt on upgrade, falling
  back to the login keychain on an unsigned build.
- Opening Settings no longer reads the Keychain, and debug logs and the AI
  wire log redact keys.

The binary also carries a `NoSyncMoveOpenAIAPIKeyIntoKeychain` migration, from
when the key was *not* in the Keychain — the `NoSync` prefix marking it as
machine-local state that never reaches a custom prefs folder.

**The 3.7 exception: custom HTTP headers.** Header values in the manual model
editor are "stored unencrypted in iTerm2's preferences" (`AICustomHeaders`).
A gateway token sent as a header lands in the plist.

**Why this matters here.** This machine sets `LoadPrefsFromCustomFolder` with
`PrefsCustomFolder` pointing at a git repository, so
`com.googlecode.iterm2.plist` is a tracked file in a public repo. That is
safe *only* because the keys are in the Keychain and no custom header is
set. Verified against the live plist in the custom folder on 3.7.6: it holds
AI settings and nothing credential-shaped, and no `AICustomHeaders`.

```
AiModel                       (a model name; a value, not a fact about iTerm2)
AitermURL                     (the provider endpoint; likewise a value)
AITermAPI                     (an integer selecting the API dialect)
AIVendor                      (an integer selecting the provider)
AI Safety Check               true
AiMaxTokens, AiResponseMaxTokens, AIVectorStore
AIFeatureStreamingResponses   AIFeatureFunctionCalling
AIFeatureHostedWebSearch      AIFeatureHostedFileSearch
AIFeatureHostedCodeInterpeter (sic - the typo is in the key name)
```

Related keys in the binary: `AiModel`, `aiProxyUserDefaultsKey`,
`llmPlatformUserDefaultsKey`, `NoSyncMoveOpenAIAPIKeyIntoKeychain`.

So the check before trusting a git-tracked prefs folder after an update is:
does that sentence still appear in the binary (`scripts/verify.sh` checks
exactly that, and caught the 3.7 rewording), and does the tracked plist
still contain nothing credential-shaped and no `AICustomHeaders`? The first
is automated; the second is a one-line grep, worth doing after any
AI-related release note.

The model name is a settings *value*, not a fact about iTerm2, so it is
deliberately absent from the manifest — it changes when you change it, and
`verify.sh` would report a false alarm.

## What the docs promise, and what they do not

Promised: network egress confined to a separate optional app; consent gated
on an admin password as a secure user default; the key in the Keychain and
yours, so traffic goes to your provider and not to the author; chats start
with zero visibility and every capability is opt-in per linked session;
composer suggestions off by default and labelled as such.

**Not** promised, and absent from every page: any data-retention statement,
any telemetry claim, and any statement of what the AI plugin itself logs.

## Related surface

- `AitermURL` is user-editable — that is how a local proxy or a
  non-OpenAI-compatible endpoint gets used.
- Chat history lives in `~/Library/Application Support/iTerm2/chatdb.sqlite`.
  It is not covered by the prefs folder and is not tracked anywhere.
- `iTermBrowserPlugin.app` is the browser feature
  (<https://iterm2.com/browser-plugin.html>), with its own
  `browserdb-*.sqlite` alongside. Same split-bundle pattern, same "installed
  but not enabled" failure mode.

## Docs vs. the binary (3.6.11, re-checked on 3.7.6)

| Claim | Reality |
| --- | --- |
| Generative AI is an iTerm2 feature | A separate signed bundle since 3.5, and deliberately so: the terminal binary cannot make network requests. |
| The AI key is a preference | It is a Keychain item. Only model, endpoint and feature toggles are in the plist. |
| The docs say which providers are supported | They name only OpenAI. 3.7.6 has OpenAI, Anthropic, Gemini, DeepSeek and Ollama as first-class providers, Apple Intelligence on-device, and presets for OpenAI-compatible gateways. |
| The AI key never touches the plist | True of keys. Since 3.7, custom header values do (`AICustomHeaders`), unencrypted. |
| The model selector appears when "Always use the recommended model from" is enabled | The AI Chat page says enabled, the settings page implies disabled. They contradict each other; try it. |
| Key names are typo-free | `AIFeatureHostedCodeInterpeter` is spelled that way in the binary. Match it exactly. |
| AI settings live in the Magic pane | They are their own sections under Settings > General. Magic is the Python API and performance pane. |
