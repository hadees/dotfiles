# The AI plugin

<https://iterm2.com/ai-plugin.html>

iTerm2 3.5 moved generative AI **out of the app** into a separate plugin. The
app on its own has the menu items and the settings pane; without the plugin
they do nothing. This is why an otherwise current iTerm2 can be missing the
feature entirely.

## What is installed here

```
/Applications/iTermAI.app             iTerm2 AI Plugin 1.1     (Homebrew cask: itermai)
/Applications/iTermBrowserPlugin.app  1.0
```

Both are read by `iterm2-doctor` (`plugins:` line) and listed as advisory
entries in `scripts/manifest.txt` — advisory because a plugin the user chose
not to install is not a fact that stopped being true about iTerm2.

The version is read the same way as the app's, off the bundle:

```bash
defaults read /Applications/iTermAI.app/Contents/Info CFBundleShortVersionString
```

## Turning it on

Settings > **General > AI**. The plugin must be installed *and* the feature
enabled *and* an API key supplied. Nothing works until all three are true.

## Where the key goes — the part that matters

The binary states it outright:

> Enter the API key for your AI provider. The key will be stored securely in
> the Keychain.

It also carries a `NoSyncMoveOpenAIAPIKeyIntoKeychain` migration, from when
the key was *not* in the Keychain — the `NoSync` prefix marks it as
machine-local state that is never written to a custom prefs folder.

**Why this matters here.** This machine sets `LoadPrefsFromCustomFolder` with
`PrefsCustomFolder` pointing at a git repository, so
`com.googlecode.iterm2.plist` is a tracked file in a public repo. That is only
safe because the key is in the Keychain rather than the plist. Verified on the
tracked copy: it contains the AI *settings* and nothing that looks like a
credential.

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

Related keys present in the binary: `AiModel`, `aiProxyUserDefaultsKey`,
`llmPlatformUserDefaultsKey`, `NoSyncMoveOpenAIAPIKeyIntoKeychain`.

So the check before trusting a git-tracked prefs folder after an update is:
does the sentence above still appear in the binary
(`scripts/verify.sh` checks exactly that), and does the tracked plist still
contain no credential-shaped value? The first is automated. The second is a
one-line grep and is worth doing after any AI-related release note.

The model name in the plist is a settings value, not a fact about iTerm2, so
it is deliberately absent from the manifest — it changes when the user changes
it, and `verify.sh` would then report a false alarm.

## Related surface

- `AitermURL` is the endpoint the plugin talks to; it is user-editable, which
  is how a non-OpenAI provider or a local proxy is pointed at.
- The chat history lives in `~/Library/Application Support/iTerm2/chatdb.sqlite`.
  It is not covered by the prefs folder and is not tracked anywhere.
- `iTermBrowserPlugin.app` is the separate browser feature
  (<https://iterm2.com/browser-plugin.html>), which keeps its own
  `browserdb-*.sqlite` alongside. Same split-bundle pattern, same
  "installed but not enabled" failure mode.

## Docs vs. the binary (3.6.11)

| Claim | Reality |
| --- | --- |
| Generative AI is an iTerm2 feature | It is a separate signed bundle since 3.5. The app ships the UI and the settings; the plugin does the work. |
| The AI key is a preference | It is a Keychain item. Only the model, endpoint and feature toggles are in the plist. |
| Key names are typo-free | `AIFeatureHostedCodeInterpeter` is spelled that way in the binary. Match it exactly if you ever write it. |
