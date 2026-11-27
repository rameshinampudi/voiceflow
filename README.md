# Airflow

**A Wispr Flow clone for macOS.** Hold the Option key, talk, let go — and clean, punctuated text appears wherever your cursor is, in any app.

Airflow recreates the core of [Wispr Flow](https://wisprflow.ai) as a small native menu-bar app you build and run yourself: push-to-talk dictation, AI editing that removes filler words and applies your self-corrections, per-app writing styles, a personal dictionary, snippets, and a voice Command Mode for rewriting selected text. It is a personal project and is not affiliated with or endorsed by Wispr.

```
 hold ⌥ ──► microphone ──► speech-to-text ──► Claude edits ──► pasted at your cursor
             (waveform pill)   (on-device)       (fillers, corrections,   (clipboard restored)
                                                  punctuation, lists)
```

## What it does

| Wispr Flow feature | In Airflow |
|---|---|
| Hold a key to talk, release to insert | Hold **⌥ Option** (either side, or pick left/right) |
| Hands-free mode | **Double-tap ⌥**; tap ⌥ again to finish, **Esc** to cancel |
| Flow bar | Floating pill at the bottom of the screen with a live waveform |
| AI auto-edits | Claude removes "um/uh", applies "at 2, no wait, 3" → "at 3", fixes punctuation, formats lists, writes numbers/emails/URLs properly |
| Context awareness | Reads the app you're in and the text before your cursor, so sentences continue naturally and names are spelled right |
| Styles per app | Formal / Casual / Very casual / Technical, per category (email, work chat, personal chat, code, AI chats, other) |
| Command Mode | Select text, hold **⌥ + ⌃**, say "make this more concise" / "translate to Hindi" / "turn this into bullets". With nothing selected it writes new text ("draft a polite reply saying I'm out until Monday") |
| Dictionary | Vocabulary words + forced replacements ("p m s engine" → `pms_engine`) |
| Snippets | Say "my calendar link" → inserts the exact saved text |
| Paste last transcript | **⌃⌘V** |
| History & stats | Every dictation (raw + final), words today, total words, average WPM |
| Mute music while dictating | Optional: mutes system output while you talk |
| Works in every app | Clipboard paste with ⌘V, then your clipboard is put back |

## Requirements

- macOS 26 or later (uses Apple's on-device `SpeechAnalyzer`), Apple silicon recommended
- Swift 6 toolchain — the Xcode Command Line Tools are enough (`xcode-select --install`)
- Optional: an [Anthropic API key](https://console.anthropic.com) for AI editing and Command Mode

## Install

```bash
git clone https://github.com/rameshinampudi/airflow.git
cd airflow
make install        # builds build/Airflow.app, copies it to ~/Applications, launches it
```

On first launch the Settings window opens. Grant:

1. **Microphone** — to hear you while you hold the key.
2. **Accessibility** — to notice the Option key in any app and paste into the focused field.
   System Settings → Privacy & Security → Accessibility → enable **Airflow**.

Then, in **Settings → AI Editing**, paste your Anthropic API key. Without a key Airflow still works, using basic offline cleanup (filler removal, "new line", capitalization).

**Keep permissions across rebuilds (recommended for development).** macOS ties permissions to the app's code signature, and an ad-hoc signature changes on every build. Run once:

```bash
./scripts/create-signing-cert.sh   # creates a local "Airflow Local Signing" certificate
make install
```

## Using it

| Do this | To |
|---|---|
| Hold ⌥, speak, release | Dictate |
| Double-tap ⌥ … tap ⌥ | Hands-free dictation (Esc cancels) |
| Select text, hold ⌥ + ⌃, speak an instruction | Rewrite the selection |
| Hold ⌥ + ⌃ with nothing selected | Have Claude write text at the cursor |
| ⌃⌘V | Paste the last dictation again |

⌥ shortcuts keep working: if you press another key, modifier or mouse button while holding ⌥, Airflow silently discards the recording.

## Speech-to-text engines

| Engine | Setup | Notes |
|---|---|---|
| **Apple on-device** (default) | None | Private and free. Streams while you talk, so text is ready ~0.3 s after you let go |
| **Whisper API** (OpenAI or Groq) | API key in Settings | Auto-detects language; audio is uploaded on release |
| **Local whisper.cpp** | `brew install whisper-cpp` + a ggml model | Fully offline Whisper |

AI editing uses Claude (`claude-opus-5-5` by default; Sonnet 5.5 and Haiku 5.5 are selectable — Haiku is the fastest and cheapest). Requests use structured outputs so only the edited text can ever reach your text field.

## Privacy

- Settings and history live in `~/Library/Application Support/Airflow/` (files are readable only by you; API keys are stored in `config.json`).
- With the on-device engine, audio never leaves your Mac. The transcript, app name and (if enabled) the ~600 characters before your cursor are sent to Claude for editing. Turn off **Use the text around my cursor** to send only the transcript.
- Nothing is recorded unless you're holding the key (or in hands-free mode). Password fields are never read and never saved to history.

## Development

```bash
make check      # unit checks for the core logic (swift run airflow-checks)
make app        # build build/Airflow.app
make selftest   # print permission / engine / key status
build/Airflow.app/Contents/MacOS/Airflow --transcribe sample.aiff --app com.tinyspeck.slackmacgap
build/Airflow.app/Contents/MacOS/Airflow --cleanup "um so lets meet at 2 no wait 3"
```

```
Sources/
  AirflowCore/            pure logic, no UI
    HotkeyStateMachine    hold / tap / double-tap / shortcut detection
    DictationPipeline     dictionary → snippets → Claude (or offline cleanup) → spacing
    PromptBuilder         system prompts and context for dictation and Command Mode
    ClaudeRewriter        Messages API over HTTP with structured output
    TextProcessing        offline cleanup, replacements, snippet placeholders
    AppClassifier         app / browser tab → writing category
    Config, History, WAVEncoder
  Airflow/                the menu-bar app
    System/               CGEventTap hotkeys, paste + clipboard restore, Accessibility context, permissions
    Audio/                AVAudioEngine capture and level metering
    Transcription/        Apple SpeechAnalyzer, Whisper API, whisper.cpp
    UI/                   flow pill, settings window, menu-bar item
Tests/AirflowChecks/      unit checks (a plain executable: the Command Line Tools
                          don't ship working XCTest / swift-testing macros)
```

## Not done yet

- Learning new dictionary words automatically from your edits after insertion
- Automatic language detection with the on-device engine (pick a language in Settings, or use a Whisper engine)
- An app icon, and notarized release builds
