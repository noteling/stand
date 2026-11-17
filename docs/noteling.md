# Stand and Noteling

Stand is the voice in the meeting. Noteling is the hands and eyes on the Mac. This page says how the two should work together, what already works, and what is proposed for Noteling. Nothing here is built yet, and nothing in the Noteling repo has been changed.

Written 2026-11-11 against Noteling 0.10.4.

**2026-11-14, read this first.** Three days on, Stand shows pages while it talks, and it does so with neither app's hands: the pages go up in a window of Stand's own, which its human shares (README, "A talk with its pages on the screen"). That needed no permission beyond the two Stand has, and nothing below was built for it. Two things about what follows have changed in that time:

- **Calling Noteling may be the wrong way round.** The user asked whether it makes sense to invoke Noteling at all, or rather to copy what it has. What I told them: copy, and only the thin slice Stand needs. Nothing fast exists in Noteling to call (the commands proposed below were never built); a command-line call would probably not carry Noteling's permissions, because macOS charges a child process's screen and accessibility access to the app that started it (likely, not verified, and it fits the failed try noted below); and every Stand user would need a second app. The cost of copying is that Stand would itself ask for Accessibility and Screen Recording, which the split below says it never does. That is undecided, and the user's to decide.
- **The rule that matters more than the split:** whatever hand Stand gets does a short list of named acts that Stand's own code chooses, in an order one part keeps. It never clicks freely on the strength of what someone in the meeting said, and it never moves while Stand is in the middle of a sentence.

## The split

| | Stand | Noteling |
|---|---|---|
| Does | Hears the call, speaks, decides when to speak | Sees windows, reads them, presses controls in the background |
| macOS permissions | Microphone, system audio recording | Accessibility, screen recording |
| Model | A voice model, with a text model behind it for facts | A text model that looks and acts |
| Lives | For the length of a meeting | All day |

Each app keeps its own permissions. Stand never asks for Accessibility or screen recording, and Noteling never opens the microphone. They talk through one narrow local interface.

Stand says what it wants in words, and Noteling decides how to do it on screen. Stand never sends coordinates or clicks. This is the same rule as between Stand's brain and its voice: hand over the point, not the script.

## What Stand needs, at three speeds

| Speed | Example | What it takes | Model involved |
|---|---|---|---|
| Reflex, under 0.3 s | Unmute before speaking, mute after | Press one named control in one named app, and know whether it worked | None |
| Glance, under 1 s | Am I muted? Is my screen shared, and which window? Who is in the meeting, and who is speaking? | Read what a window says as text | None |
| Look and act, seconds | "What is on the shared screen?" "Go to the next slide." Driving a demo while presenting | A picture of a window, or a goal carried out in it | Noteling's |

The reflex path must not pass through any model. Stand starts answering about a second after a question ends, and unmuting has to fit inside that.

## What Noteling already has

Read in its source. None of it has been run against a meeting app.

- `Noteling --background-click <bundle-id> --label "<text>"` presses a control by name without taking focus or moving the cursor, and exits 0 when the control reacted. It is a diagnostic: it runs a self-test, takes before-and-after snapshots and prints a report.
- `Noteling --ask "<goal>" --control --background --target <bundle-id>` runs Noteling's full loop on another app's window. This is the look-and-act speed.
- Notes are files in a folder, according to the README. I have not looked at their format.

Measured here: starting the Noteling binary for one command takes 1.1 s the first time and 0.4 s after that, before any accessibility work. That is fine for a glance and too slow for a reflex.

Not verified: any press in Zoom. From this shell, Noteling listed Zoom's window ("Zoom Workplace") and then could not resolve it. Either there was no meeting window to resolve, or Accessibility did not apply to a Noteling started from this shell. A two-minute test with a person settles it; see "Order of work".

## Proposed changes to Noteling

In the order I would do them.

### 1. `--press`: a plain, fast press (small)

```
Noteling --press <bundle-id> --name "Unmute Audio" [--menu] [--title <window part>] [--json]
```

- **Match the whole name, not a part of it.** `--background-click` finds a control whose name *contains* the label, and "mute" is inside "unmute". Asked to mute, it can unmute.
- **Accessibility press first** (rung A), the coordinate click only as a fallback.
- **Menu bar items count.** A meeting app's toolbar hides itself when the mouse is away; its menu bar does not. I expect Zoom's menu item to carry the state in its name (Mute Audio, Unmute Audio), but have not checked.
- **Three results**, as an exit code and one line of JSON: pressed and the state changed, no such control, control found but nothing changed. "No such control" is how Stand learns it was already unmuted.
- No self-test and no report on each call.

### 2. `--read-window`: what a window says, without a model (small to medium)

`--read-page` already does this for a browser page. The same for any app's window: roles, names and values, as JSON, with `--contains` to filter. Stand would use it to learn whether it is muted, whether a screen is being shared, who is in the meeting and, if the meeting app exposes it, who is speaking. That last one matters: Stand hears one stream of sound and cannot put names to voices.

### 3. Meeting words in `IrreversibleGuard` (small)

The confirm words cover mail and forms: send, submit, pay, delete. A meeting has its own: leave, end meeting, record, share screen, admit, mute all. Stand's hands should never press those without its human's word. Unmuting is its own case. It can be undone, but it opens a microphone in someone's room, so it should need a standing permission from that person rather than a prompt each time.

### 4. `Noteling --mcp`: one long-lived tool server (medium to large)

Four tools: `press_control`, `read_window`, `look_at_window` (returns an image), `do_in_window` (the background lane, given a goal in words).

- **Why a server:** one connection for the whole meeting, so a call costs milliseconds instead of a new process each time.
- **Why MCP:** Stand's brain has to speak MCP anyway, to use the servers you already have. Noteling would be one more. Claude Code and any other MCP client would get hands and eyes the same day.
- **How:** the running app does the work and a small stdio shim forwards to it. Noteling's Claude Code connection already does this with `claude_mcp.py`. The grants then stay with the Noteling app, whoever starts the client.

### 5. A note from outside (small)

`Noteling --note "<text>"`, or a documented file format. When Stand says "I'll follow up on that after the meeting", the promise becomes a sticky on its human's screen.

### Not proposed for now: sharing the connection code

Stand's brain reaches Claude through two small clients of its own, using Noteling's setting names (`connectionMode`, `apiBaseURL`, `apiHeaders`, `model`, `effort`). Making `FamiliarRuntime` a library would give Stand the scripted gateway secrets and the tool bridge for free, but Stand would then build against Noteling's repo. Stand asks one question and gets one answer, so the copy is cheap. Worth revisiting when the brain needs a full tool loop.

## Notes from GitHub and from folders: Stand fetches them itself, Noteling's way (decided 2026-11-12)

Noteling gets a team's tools onto every Mac with no git: one request to GitHub's API for the newest commit of a branch, and when that has changed, the commit as an archive, unpacked and swapped in whole (`LinkedTools.swift`). A person's own tools are a folder on the Mac (`toolsDir`). A pack's `docs/` are sent with each request up to `docsStuffLimitChars`, and read through tools past that.

Stand now does the same for its notes, in its own code (`GitHubSource.swift`, `Notes.swift`): a list of folders and repositories in `brain.json`, copies kept in `linked/`, the same setting name for how much is sent whole. It does not ask Noteling to fetch or to answer. The reasons:

- **Time.** A lookup has to be one request to a model, because people are waiting: about two seconds. `Noteling --ask` is built around the page in front (packs apply by the page's address or app) and runs Noteling's whole tool loop, which is the right shape for the pen and the wrong one for "what was the budget?" in a meeting.
- **Standing alone.** Stand has to work on a Mac without Noteling, with its own model connection.
- **Size.** The fetch is about 300 lines.

What the two now share, with no code in common:

- **One repository can serve both.** Stand reads every Markdown and text file in a repository, so a team's tools repository linked in Noteling can be linked in Stand as it is, and Stand answers from the packs' `docs/`. Stand ignores the scripts.
- **Noteling's copy can be Stand's source.** Add `~/.noteling/linked-tools` or `~/.noteling/tools` in Stand as a folder, and Noteling does the fetching: Stand reads whatever copy Noteling keeps current, and needs no token of its own. On this Mac those folders hold 4 and 23 Markdown files.

What stays with Noteling: a pack's **scripts** fetch live data (an order's state, a page's status), with secrets from the Keychain and the Mac's proxy. That is fetching in a deeper sense than documents, and rebuilding it in Stand would be a second copy of Noteling's runtime. It belongs behind proposal 4: with `Noteling --mcp`, a pack's tools become things Stand's brain can call when the voice model asks. A lookup of that kind will take longer than two seconds, so Stand will need to say "give me a moment" and go on with the meeting.

## What changes in Stand

- **Hands around speech.** When the voice model starts a turn, Stand asks for unmute and holds playback until the answer comes back. A few seconds after it finishes, it restores the state it found. Off until its human turns it on.
- **An MCP client in the brain.** `look_at_window` and `do_in_window` become things the brain can do when the voice model asks. "What's on the shared screen?" becomes: look, describe, hand the point to the voice.
- **Names for voices.** If `read_window` can say who is speaking, the session passes it to the voice model as a stage-manager line.
- **The panel out of screen shares.** Done on 2026-11-12, the way Noteling does it (`sharingType = .none`), on by default and switchable in the Stand menu, because the panel now holds the brief and the notes passed to Stand. Not yet checked against a call's screen sharing.

## Order of work

1. **A two-minute test, no code.** In a Zoom meeting by yourself, run `build/Noteling.app/Contents/MacOS/Noteling --background-click us.zoom.xos --label "mute audio"`. It toggles your mute once, and tells us whether Zoom's controls can be reached at all and under what names.
2. **`--press`, then Stand's unmute around speech.** Stand cannot speak up in a discussion (the second scenario) without it.
3. **`--read-window`, then a probe of what Zoom shows about participants and the active speaker.**
4. **`--mcp`, and the MCP client in Stand's brain.**
5. **Driving a demo.** Watch Me keeps the steps of something shown once. A talk could name a kept path and tie each step to a section, so Stand shows the product while it talks about it.

None of this is needed for the first test. In the self-introduction talk the human unmutes once and Stand presents.

## One operator as the brain of both (raised 2026-11-12; taken up for this phase as a compromise)

**Decided the same day, in the user's words: an external command-line tool may be the brain for this phase, Claude Code is fine, and it is "a compromise, not design".** Stand's brain is now built that way (`ClaudeCodeBrain`): one Claude Code process for the meeting, which reads the notes, may search the web, can be given MCP servers, and asks Stand's human in the panel before anything beyond reading and searching. What follows is the reasoning from before that decision, kept because the open points are still open: nothing here settles what the brain should finally be, and Noteling has not been changed.

What this makes of proposal 4: once Noteling can offer its hands and eyes as an MCP server, giving them to Stand is one line in Stand's `mcpConfig`. Under the rule to ask as little as possible, Stand's brain would then look and press without asking, except for a tool whose name says it cannot be undone. That differs from Noteling's own guard, which leans towards asking; the two would need one answer for a press that sends something.


The user's thought: Stand and Noteling both need a brain that is an operator on the computer, outside either app, and the Claude Code CLI run headless could be it. That operator already has what the MVP asks of Stand's brain: local files, skills, MCP servers.

The picture it gives: one operator; Stand is its ears and mouth; Noteling is its eyes and hands, offered to it as an MCP server (proposal 4, which then matters more than the other four). Neither app calls the other. Noteling's Claude Code connection is already half of this: it starts the CLI and bridges Noteling's tools into it. The difference is who owns the loop.

What was measured the same day (CLAUDE.md has the figures): kept open and asked one thing after another, the CLI answers in about a second, with this Mac's whole setup loaded, and in two to four seconds when it has to search files. So it is fast enough to be the brain of a meeting, as long as it is one process for the whole meeting and not one per question.

What it would force:

- **Authority.** An operator in a meeting hears whatever anyone says, and has tools. It should be able to read and look by default, and anything that changes something should wait for its human to press a button in the panel. The CLI can hand permission questions to its host (`--permission-prompts host`) and has a mode without code-running tools (`--restricted`).
- **The connection.** The brain was required not to depend on Claude Code. The operator would. A gateway would then be set in Claude Code's own settings, and the Messages API brain would remain as the lesser path for a Mac without it.
- **Other people's Macs.** Everyone who uses Stand would need Claude Code installed and signed in.

## Open questions

- Does Zoom expose the active speaker to Accessibility? Meet runs in a browser tab and Teams is a web view, so each will need its own look.
- Should unmuting be Stand's decision alone, or should it raise its human's hand and wait to be called on? Both are one press.
- Whose model pays for look-and-act: Noteling's connection, or Stand's brain? This page assumes Noteling's, since it already owns the judgment about acting on screen.
