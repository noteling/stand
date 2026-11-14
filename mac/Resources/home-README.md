# Stand's folder on this Mac

Everything here is yours. The app itself holds who Stand is and how it behaves.

| Here | What it is |
|---|---|
| `.env` | Your keys. The panel writes the Gemini key here the first time. |
| `brain.json` | How Stand looks things up: which model, which folders and GitHub repositories, whether it may use the web and your Claude Code setup. |
| `brief.md` | What you wrote in "For this meeting". |
| `context/` | Notes: put Markdown or text files here and Stand can look things up in them. |
| `linked/` | Copies of the GitHub repositories you added. Replaced on every update; do not edit. |
| `runs/` | One folder for each session: the recording, a transcript, what happened and when. |
| `reports/` | What "Make a Problem Report" in the Stand menu makes: one zip with the last session and what this Mac gives Stand to work with. No keys, no notes. Send that when something goes wrong. |

Stand can give a talk, or sit in a discussion without one: choose "None: join the discussion" under Talk. In a discussion it speaks when spoken to and when "For this meeting" gives it a reason, so write there what it is in the meeting for.

To change how Stand behaves on this Mac, put a file at the same path as the one inside the app, for example `prompts/presenter.md`, `prompts/attendee.md` or `talks/my-talk.md`. A file here wins over the app's own. The app's copies are in `Stand.app/Contents/Resources/defaults`.

Looking things up needs Claude Code on this Mac, signed in. Without it Stand still talks and listens, and says when it does not know.
