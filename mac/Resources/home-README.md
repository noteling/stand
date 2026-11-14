# Stand's folder on this Mac

Everything here is yours. The app itself holds who Stand is and how it behaves.

| Here | What it is |
|---|---|
| `.env` | Your keys. The panel writes the Gemini key here the first time. |
| `brain.json` | How Stand looks things up: which model, which folders and GitHub repositories, and what it may reach beyond them. |
| `brief.md` | What you wrote in "For this meeting". |
| `context/` | Notes: put Markdown or text files here and Stand can look things up in them. |
| `linked/` | Copies of the GitHub repositories you added. Replaced on every update; do not edit. |
| `runs/` | One folder for each session: the recording, a transcript, what happened and when. Nothing deletes these but you. |
| `reports/` | What "Make a Problem Report" in the Stand menu makes: one zip with the last session, its recording included, and what this Mac gives Stand to work with. No keys, no notes. |

Stand can give a talk, or sit in a discussion without one: choose "None: join the discussion" under Talk. In a discussion it speaks when spoken to and when "For this meeting" gives it a reason, so write there what it is in the meeting for.

To change how Stand behaves on this Mac, put a file at the same path as the one inside the app, for example `prompts/presenter.md`, `prompts/attendee.md` or `talks/my-talk.md`. A file here wins over the app's own. The app's copies are in `Stand.app/Contents/Resources/defaults`.

Looking things up needs Claude Code on this Mac, signed in. Without it Stand still talks and listens, and says when it does not know.

## Before you take it into a meeting

- **Tell the people there.** Stand listens to the meeting and keeps a recording of every session in `runs/`.
- **What leaves this Mac.** The meeting's sound goes to Google, under your key, for as long as Stand is in the meeting. What Stand looks up, and the notes it looks in, go to Anthropic, under the Claude Code login on this Mac. Nothing goes to the people who make Stand.
- **What it costs.** The Gemini key is yours and so is the bill: about 20 cents for the three minutes in which Stand introduces itself and takes a few questions, and by our estimate 5 to 10 dollars for an hour of steady talk. The panel shows what your sessions have cost so far.

## What Stand may reach

Anyone who speaks in the meeting can ask Stand things, so what Stand can reach, the meeting can reach. It starts out cautious:

- It looks in the notes and folders you give it, and searches the web.
- Before anything else (a web page, another file on this Mac, a tool of an MCP server) it asks you in the panel, with **Allow** and **No**. No answer in 20 seconds is a no.
- Your Claude Code setup, with whatever mail, calendar or other tools it has, stays out.

`brain.json` changes that. `"claudeCodeSetup": true` brings your Claude Code setup in. `"ask": "irreversible"` has Stand ask only before a tool whose name says it cannot be undone (send, delete, pay and the like), and do everything else without asking. Turn these on knowing who will be in the room.

## When something goes wrong

github.com/noteling/stand/issues is the place. A problem report's zip holds the last session's recording: send it to a person you trust with that, and do not attach it to a public issue.
