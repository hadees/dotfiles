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
you never run it, iTerm2 finds it.

Installed here:

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
| Timeout | "The maximum time to wait for a response to an AI query." |

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

The binary answers it. Endpoints and identifiers present in 3.6.11:

```
https://api.openai.com/v1/responses          (this machine's AitermURL)
https://api.anthropic.com/v1/messages        anthropic-version header
https://api.deepseek.com/v1/chat/completions deepseek-reasoner
```

plus `Azure`, `Gemini`, `Llama` and `Custom` as selectable values. So a
non-OpenAI provider or a local proxy is configured by turning off *Always use
the recommended model from*, opening **Configure AI Model Manually**, and
setting Model / Token Limit / URL / API / Features by hand.

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
| Type for You | sends keystrokes to the terminal |
| View History | your command history in the linked session |
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

## Where the key goes — the part that matters here

The binary states it outright:

> Enter the API key for your AI provider. The key will be stored securely in
> the Keychain.

It also carries a `NoSyncMoveOpenAIAPIKeyIntoKeychain` migration, from when
the key was *not* in the Keychain — the `NoSync` prefix marking it as
machine-local state that never reaches a custom prefs folder.

**Why this matters here.** This machine sets `LoadPrefsFromCustomFolder` with
`PrefsCustomFolder` pointing at a git repository, so
`com.googlecode.iterm2.plist` is a tracked file in a public repo. That is
safe *only* because the key is in the Keychain. Verified against the tracked
copy: it holds AI settings and nothing credential-shaped.

```
AiModel                       "gpt-5.5"
AitermURL                     "https://api.openai.com/v1/responses"
AITermAPI                     2
AiMaxTokens                   1050000
AiResponseMaxTokens           128000
AIVectorStore                 0
AIFeatureStreamingResponses   AIFeatureFunctionCalling
AIFeatureHostedWebSearch      AIFeatureHostedFileSearch
AIFeatureHostedCodeInterpeter (sic - the typo is in the key name)
```

Related keys in the binary: `AiModel`, `aiProxyUserDefaultsKey`,
`llmPlatformUserDefaultsKey`, `NoSyncMoveOpenAIAPIKeyIntoKeychain`.

So the check before trusting a git-tracked prefs folder after an update is:
does that sentence still appear in the binary (`scripts/verify.sh` checks
exactly that), and does the tracked plist still contain nothing
credential-shaped? The first is automated; the second is a one-line grep,
worth doing after any AI-related release note.

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

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| Generative AI is an iTerm2 feature | A separate signed bundle since 3.5, and deliberately so: the terminal binary cannot make network requests. |
| The AI key is a preference | It is a Keychain item. Only model, endpoint and feature toggles are in the plist. |
| The docs say which providers are supported | They name only OpenAI. The binary carries endpoints for OpenAI, Anthropic and DeepSeek plus Azure/Gemini/Llama/Custom selections. |
| The model selector appears when "Always use the recommended model from" is enabled | The AI Chat page says enabled, the settings page implies disabled. They contradict each other; try it. |
| Key names are typo-free | `AIFeatureHostedCodeInterpeter` is spelled that way in the binary. Match it exactly. |
| AI settings live in the Magic pane | They are their own sections under Settings > General. Magic is the Python API and performance pane. |
