# Stand

Stand is an AI that attends meetings. It joins, it already knows the background, and it speaks up, out loud, as a character with a goal.

- **Who Stand is:** [identity/stand.md](identity/stand.md). Stand reads this same file as its knowledge of itself.
- **How it sounds:** [identity/character.md](identity/character.md) when it gives a talk, [identity/character-attendee.md](identity/character-attendee.md) when it sits in a discussion
- **The first test:** Stand introduces itself, is interrupted, answers, and gets back on course. The talk is [talks/introducing-stand.md](talks/introducing-stand.md).
- **The second:** Stand sits in a discussion among people, says nothing while they talk to each other, answers when spoken to, and speaks up when the discussion reaches what it is there for. A first form of it is built; see "Sitting in a discussion" below.
- **Choices made along the way:** [DECISIONS.md](DECISIONS.md)
- **Where it stands:** early. It was started on 2026-11-11, most of what is described below has run only with scripted voices, and the Mac app has not yet sat in a real call. The statuses at the end say what has been tried and what has not.

## The Mac app (in progress)

`mac/` is the native app, a Swift package. Build it and open it:

```
mac/scripts/build.sh          # builds mac/build/Stand.app
open mac/build/Stand.app
```

A small panel floats above your call. Before a meeting it holds what Stand is given to work with: the talk, a brief for this meeting, and the places it looks things up. Press **Start the talk**, and Stand presents through the Mac's speakers. Or choose **None: join the discussion** under Talk and press **Join the meeting**: Stand gives no talk, and takes part as one of the people in the room. During the meeting, **Hush** (or Control-Option-S from anywhere) makes it stop talking at once, and the text field passes Stand a note that only Stand sees (Control-Option-N from anywhere puts the keyboard there). The first run asks for two permissions: the microphone, to hear you, and system audio recording, to hear the call.

Every session is saved in `runs/` with a recording, a transcript and a summary.

### A talk about one of your systems

Stand can give a talk it has prepared itself, about something it has the documents and the code of.

1. Under **Notes…**, add the folder (or the GitHub repository) that holds the system's documents and code. That folder is the boundary: Stand's brain may read and search whatever is in it, and nothing outside it unasked.
2. In **For this meeting**, write a line or two: what to present, to whom, for how long. "Introduce the Ledger service to the support team. Ten minutes. They are not engineers."
3. Press **Prepare a talk from this**. Its brain reads the documents and the code and writes the talk, which takes a minute or two. The new talk is chosen under Talk. **Read the talk** opens it: it is a file under `talks/`, yours to change.
4. Press **Start the talk**.

The talk is a plan of points in numbered sections, and after them a part headed "If asked": the facts people are most likely to ask for, which Stand then has ready. Anything else it looks up in the documents and the code while people wait, which takes one to seven seconds.

```
$BIN --probe prepare "Introduce the Ledger service to the support team. Ten minutes."   # the same from the command line
$BIN --probe sources --list      # each source: its notes, how many other files the brain can search there, and where they are
```

The brain works in the folder itself, with its own search (grep): nothing is copied or indexed, and it does not matter what kind of files they are. Two things in a folder it does not touch: what the project's own `.gitignore` leaves out, and files that hold keys or passwords by their names (`.env`, key files, configuration called "secrets" or "credentials"). The panel says how many notes a folder has and how many other files.

Tried with Stand's own repository as the system, scripted voices only (see the status below). Not tried: a code base much bigger than this one, and anything by voice.

### Whose voice

Stand speaks with one of thirty voices, and which one is yours to choose: **Voice** in the panel. The menu gives each voice as the voice service describes it ("Kore: firm, direct, authoritative"). **Hear it** says a few lines in the chosen one, about a second after you press it, and that is how to choose: the descriptions are the service's, and nobody here has heard the voices. The choice is kept on this Mac. Until you make one the voice is Kore, which every session before 2026-11-13 had.

```
$BIN --probe voice Puck Charon       # the same lines in those voices, kept as WAV files; no sound
$BIN --probe voice --all --play      # all thirty, one after another, through the speakers
$BIN --probe voice --as-the-panel    # presses Hear it with the sound off, and says PASS or what went wrong
$BIN --rehearse --voice Puck         # a rehearsal in another voice (STAND_VOICE=Puck does the same for any run)
```

The thirty are listed in `prompts/voices-gemini.txt`, and they are all there is:

- The service's catalogue has 2,114 voices, most of them for its text-to-speech models. Its live model, which is the one Stand talks through, takes the thirty with names of their own.
- Given any other name, the live model does not refuse. It speaks with Zephyr's voice and says nothing about it: asked for a man's voice from the catalogue, it answered in a woman's. So Stand refuses a name that is not on its list, before the session starts.
- **Your own voice, or any person's, is not possible today.** The service can copy a voice from a recording, with a recorded consent from the person, and can make one from a description, but only for the text-to-speech models. The live model ignores both when reached with a key, as Stand reaches it; Google's cloud platform has it for live sessions, for selected customers. Going through text-to-speech would put a transcript between hearing and speaking, which is the one thing Stand does not do.
- **A way round it was looked into and not built:** a small model on this Mac that turns Stand's speech into another voice as it is played, with no transcript and about a tenth of a second of delay. `docs/own-voice.md` has what was found, why the vendors hold voice copying back, and what a first try would be. The user's word, 2026-11-13: "not worth it yet".

A sample costs about a quarter of a cent the first time a voice is heard and nothing after that until Stand quits. Samples are not kept among the runs and are not in the panel's count of what sessions have cost.

### Putting Stand on another Mac

```
mac/scripts/package.sh              # mac/dist/Stand-<date>.dmg, for Apple silicon and Intel, macOS 14.2 or later
mac/scripts/package.sh --notarize   # the same, checked by Apple, so that it opens with a double click
```

`--notarize` needs two things on the Mac that builds. Both belong to an Apple developer account, neither to an app: a Developer ID Application certificate, and a saved Apple login for Apple's notary service. Stand has a login of its own for this, a notarytool profile called `stand-notary`, and uses no other app's. It is made once. Make an app-specific password at account.apple.com (under Sign-In and Security), then:

```
xcrun notarytool store-credentials stand-notary --apple-id <your Apple ID> --team-id <your team ID>
```

It asks for that password and keeps it in the keychain. Until the profile exists, `--notarize` stops before building and prints these steps.

The disk image holds the app and a "Read me first". The app carries who Stand is and how it behaves (`identity/`, `prompts/`, and the talk that introduces Stand; a talk its brain prepared on this Mac stays on this Mac). Nothing of yours goes into it: no keys, no brief, no notes, no runs.

On the other Mac everything of yours lives in `~/Stand`, which the app makes the first time: `.env`, `brain.json`, `brief.md`, `context/`, `linked/`, `runs/`. A file put there at the same path as one inside the app (`prompts/presenter.md`, `talks/my-talk.md`) wins over the app's, which is how behaviour is changed on that Mac without a new build. The panel shows which build it is.

The first time, on that Mac:

1. Without `--notarize`, macOS refuses to open the app until told to: System Settings > Privacy & Security > Open Anyway.
2. The panel asks for a Gemini API key, once, and keeps it in `~/Stand/.env`.
3. macOS asks for the microphone and for system audio recording when the first talk starts.
4. Looking things up needs Claude Code on that Mac, signed in. Without it Stand talks and listens, and says when it does not know.

To report on a session from that Mac, choose **Make a Problem Report** in the Stand menu. It makes one zip in `~/Stand/reports` and shows it in the Finder: what that Mac gives Stand to work with (the build, whether there is a key, the microphone permission, where the brain is, how many notes), `brain.json`, and the last session's record with its recording as a small audio file. It holds no key and no notes, and nothing is sent anywhere: you send it. `Stand --probe doctor` prints the first part by itself.

If the panel says the Gemini account has run out of credit, that is the account behind the key, and credit is added at ai.studio/projects. It ran out here on 2026-11-12: $20, after 264 sessions and about 470 minutes. See "What a session costs" below.

Checked from the packaged app on this Mac, pointed at an empty folder as its own: it makes the folder, answers from a note dropped in it, connects to the voice model, starts the brain, keeps a pasted key, and passes the north-star script. The Intel half ran through Rosetta as far as reading its files. Not checked: hearing and speaking under this signature (macOS asks for the two permissions again, which takes a person), and opening it on a Mac that has never seen it.

### Sitting in a discussion

Stand does not have to give a talk. With **None: join the discussion** chosen, it is one of the people in the meeting. It listens, and most of the time it says nothing, as anyone in a meeting does.

It speaks when:

- someone speaks to it, by name or by asking it something;
- someone asks the whole room for a fact it can find ("does anyone know how many came on Tuesday?");
- the discussion reaches something the brief says it is there for, or the people are about to settle something that goes against it;
- you pass it a note that says to.

What it says is short: a sentence or two, and then the meeting goes on. If someone starts speaking while it is speaking, it stops, and makes the rest of its point afterwards if it still matters. If the people hear its point and decide otherwise, it lets the point go.

Stand has the last few minutes of the meeting word for word. What was said before that, and what its notes say about the matter in hand, it has from its prompter (see "The prompter" below). Asked at the end of a meeting about something said at its start, it answers from that.

The brief matters more here than in a talk, because it is what gives Stand a reason to speak without being asked: "the next session must not be before the 19th: the room is booked only from then". With nothing in the brief, Stand speaks only when spoken to, and the panel says so.

The scripted discussions, which need no person and make no sound (`mac/scripts/tally.py --last 6` adds runs up line by line):

```
export STAND_CONTEXT=poc/heckler/context
$BIN --rehearse poc/heckler/discussion.json            # two people plan; two questions to Stand, two things its brief is about
$BIN --rehearse poc/heckler/discussion-long.json       # twelve minutes, three voices, long silences
$BIN --rehearse poc/heckler/discussion-banter.json     # fast talk that is none of its business, with "stand" as an ordinary word
$BIN --rehearse poc/heckler/discussion-pushback.json   # it is overruled, then cut off in the middle of an answer
$BIN --rehearse poc/heckler/discussion-notes.json      # notes passed to it during the discussion
$BIN --rehearse poc/heckler/discussion-open.json       # no brief at all
$BIN --rehearse poc/heckler/discussion-pauses.json     # a pause in the middle of a sentence; someone starting just as Stand does
$BIN --rehearse poc/heckler/discussion-names.json      # six ways of saying its name
$BIN --rehearse poc/heckler/discussion-silence.json    # four minutes in which nobody speaks
$BIN --rehearse poc/heckler/discussion-memory.json --context-tokens 6500 --context-keeps 5000   # does it remember the start? add --no-prompter to see it forget
$BIN --rehearse poc/heckler/discussion-ask.json        # two things only its human can say
$BIN --rehearse poc/heckler/discussion-prompter.json   # a wrong figure that the notes have right, and two questions the notes answer
$BIN --rehearse poc/heckler/discussion-tail.json       # half a minute: its name a second after someone else's sentence
$BIN --rehearse poc/heckler/discussion-fact.json       # a brief that is one bare fact: Stand keeps it to itself until it is asked for or a decision gets it wrong
$BIN --rehearse poc/heckler/discussion-hanging.json    # a question between two other people, answered after four seconds, and one that nobody answers
$BIN --rehearse poc/heckler/discussion-known.json      # a brief that asks Stand to make one thing known, and to watch for two others
$BIN --rehearse poc/heckler/talk-memory.json --context-tokens 6500 --context-keeps 5200   # a talk, not a discussion: does its brain remember for it? add --no-prompter to see it forget
```

A line of a script can also name what Stand must not say after it (`mustNotSay`): the pushback script uses it to catch an overruled point coming back.

How these went is under "Status" below. All of it is with the Mac's synthetic voices. No person has spoken to Stand in a discussion yet, and it has not been run out loud.

### The prompter

A second brain sits behind Stand's voice in every meeting. In a talk it is Stand's memory (see "In a talk" at the end of this section). In a discussion it sits behind Stand's voice, the way a prompter sits in front of an actor. The voice model hears the room and does the speaking. It cannot see the notes, and it holds only the last few minutes. The prompter follows the meeting as the voice service transcribes it, knows the notes and the brief, and keeps one short sheet in front of Stand:

- **So far:** the thread of the meeting in at most 90 words: what has been decided, who promised what, what Stand itself has said.
- **In play:** the facts from the notes and the brief that bear on what is being discussed now. Stand answers from these at once, where it used to say "let me check" and go to look.
- **Owed:** what Stand said it would come back to.
- **Worth saying:** now and then, one point for Stand to make without being asked.

The first three are slipped to Stand in a quiet moment, when they have changed, as a message it does not answer. The fourth is handed to it the way a note from you is, and Stand says it in its own words. The prompter raises a point only when:

- someone has stated as fact something the notes or the brief have otherwise, and it matters to what is being decided ("Tuesday had 14 people, not 20");
- the meeting is about to settle something the brief says Stand is there to prevent;
- someone asked the room for a fact, nobody gave it, and the notes have it;
- Stand was asked something and did not answer, or a question put to "you" has hung in silence for three seconds. Its name is easily lost from the head of a sentence, and such a question was probably its own.

What keeps the prompter from being a nuisance:

- A point is passed once.
- It waits for a second and a half in which nobody is speaking. It gives way to a note from you, and it is dropped if Stand has spoken in the meantime or if no opening comes in half a minute.
- A point Stand has made, and the meeting has heard and decided against, is never brought back.
- Nothing is raised that the transcript does not show plainly.

**When to correct.** For now Stand makes every point its prompter raises, unless it has made it already or the meeting has said no. When a correction is welcome depends on the people and the meeting: nobody wants the chief executive corrected on a small figure while they are making their point. In the long run that has to be something Stand can be told, and in time learns. It is not built. What there is today is the brief, which the prompter reads. With a line in it saying not to correct one person on small figures, the prompter left the wrong lunch figure alone in 3 offline runs of 3; without the line it raised it in 3 of 3. That has not run in a session.

The panel shows the latest point under "Its brain thinks worth saying", and a session's `transcript.md` has every sheet and every point, with what became of it.

**In a talk** two things stand in for the memory the voice model does not have, which is everything older than about three minutes.

- **The stage manager keeps the place.** It hands Stand the talk one numbered section at a time, with that section's points, and the next the moment Stand finishes (`prompts/stage-manager-section.txt` and its neighbours; `nextInTalk` in `StandSession`). When Stand is stopped in the middle of a section, the stage manager works out from Stand's own words which points the audience did not hear, and gives those back before the next section. The whole plan is still in Stand's instructions, so it can skip ahead or go back when someone asks. `--whole-talk` on a rehearsal is the old way, in which Stand kept its own place and was only told to carry on.
- **The prompter remembers the audience.** It is given the plan of the talk and everything the audience has heard, and keeps on its sheet what people have asked, what Stand answered, and what Stand said it would come back to. It never prompts Stand to speak there, and it says nothing of where the talk stands beyond the last section finished: a sheet is always some seconds behind, and one that listed points "still to make" sent Stand back over them. The sheet reaches Stand when its own speech has run out, and never in the moment after someone has asked a question: sent then, it took the turn in which Stand should have answered, and the question went unanswered for 26 seconds. Rules: `prompts/brain-prompter-talk.md`; how it reaches Stand: `prompts/talk-sheet.txt`; what Stand is told about both: "What you remember" in `prompts/presenter.md`.

This is the one place a transcript is used. What Stand hears and says still goes from sound to sound: the prompter decides what is put in front of Stand, never its words. Like the brain that looks things up, it is the external `claude` program for this phase (a second copy of it runs during a discussion), and that is a stopgap, not the design.

```
export STAND_CONTEXT=poc/heckler/context
$BIN --rehearse poc/heckler/discussion-prompter.json                # with the prompter
$BIN --rehearse poc/heckler/discussion-prompter.json --no-prompter  # Stand left to its own tools: the wrong figure stands
$BIN --probe prompter runs/<a discussion> --brief poc/heckler/discussion-brief.md   # a finished meeting's transcript played to the prompter: what it would have written. No voice model.
$BIN --probe prompter poc/heckler/prompter/lunch.md --brief poc/heckler/prompter/brief-leave-small-things.md   # a brief that says to let small figures go: no correction
```

### Who marks when someone is speaking

A voice service decides for itself when someone has started and stopped speaking, and gives its model a turn each time. Gemini's did this badly for a meeting: it often lost the first word of whatever was said about a second after someone else had finished, which is when the model is taking its own turn. Stand's name at the head of a question arrived as "And", and in the north-star script "Thanks, that's all the questions we have" once arrived as "再见".

So Stand marks speech itself, from how loud the room is, and hands the service each utterance from just before its first sound. A sound counts as a voice when it is well above the room's own steady noise and lasts longer than a click or a key press; an utterance ends after 0.7 seconds of quiet. Replies come about 0.3 seconds later than before, and what Stand hears is whole.

This holds for talks and discussions. It was checked with the scripted audience, with a steady noise and an echo of Stand's own voice added to the room. It has not been run out loud.

One thing about it is weaker than the rest. After those runs, an independent review of the code found that the detector judged sound a chunk at a time, and a real microphone delivers chunks five times as long as the scripted audience does: someone cutting in on Stand would have been noticed up to a second late. The detector now works in fixed 20 ms steps whatever it is given, ignores clicks, and has a rule for cutting in that allows for the dips in a real voice. That form was checked by playing recordings through it (`$BIN --probe marker <run folder>`): the two real-microphone recordings there are, and several of the day's rehearsals, each marking the same utterances as before. No session has run with it, because the Gemini credit had run out.

Two switches, for one run each: `STAND_OWN_ACTIVITY=off open mac/build/Stand.app` goes back to the service's own detection, and `STAND_VOICE_LEVEL=300` lowers the least a voice has to be (500 out of 32768 as it stands) for a room with quiet voices.

Two more things were learned on the night of 2026-11-12, and a discussion is now heard this way. Both were measured with one question, "Stand, anything else from you before we finish?", said a second after someone else's sentence to a Stand that had not yet spoken (`poc/heckler/discussion-tail.json`):

- **One sentence, one utterance.** For an evening Stand let several people's sentences run into one utterance when it had no part in the exchange, so as to take fewer turns. Of such an utterance the model catches less: it answered the question in 21 runs of 43, and the service's transcript of it usually had no "Stand" in it. Shortening the pauses inside the long utterance did not help (5 of 8), nor did telling the model that the last sentence is the one that matters (2 of 6 against 1 of 6).
- **A new utterance waits for the model's turn on the last one.** When an utterance ends the model takes a turn, which is mostly a decision to say nothing and is over in about half a second. If someone starts speaking within that half second and the service is told at once, it drops the turn. With the turn it loses the new utterance from its own transcript (26 runs of 26 of the discussion script), and the model answered the question in 6 runs of 17. So the start is kept back, with its sound, until the turn is over, which is usually a quarter of a second and at most two seconds. If Stand begins to speak in that time, the service is told at once, and Stand gives way as it does whenever two people start together.

With both, the question was answered in 22 runs of 22, 14 of them with no prompter, and the transcript had it whole every time. The price is turns: about three times as many (see "What a session costs"). `--ends-after-when-out 1.5` and `--turn-finishes-within 0` on a rehearsal bring the old ways back, one each.

### What a session costs

The voice service does not charge by the minute. It charges every turn of the model for everything the model has in mind at that moment: Stand's instructions (about 3,800 tokens of text, its tools included), and all the speech of the session that it still keeps, its own and everyone else's, at 25 tokens a second. A turn is each time the model answers, is told to carry on, is passed a note, or decides to say nothing after someone stops speaking.

At the prices of 2026-11-12 ($3.00 for a million audio tokens in, $12.00 out, $0.75 for text in):

- the instructions cost about 0.3 cents on every turn;
- each minute of speech the model still keeps adds about 0.45 cents to every turn;
- what Stand itself says costs 1.8 cents a minute.

So a session costs more the more turns it has and the more the model is keeping. One thing holds that down, and a second did for one evening:

- **Stand's voice keeps the last three minutes word for word, and its brain keeps the rest.** The voice model is told to hold its instructions plus at least three minutes of sound (`rememberMinutes`; `STAND_REMEMBER_MINUTES` for one run), and what is older is dropped. Every turn is billed for everything held, at about 1,500 tokens for a minute of speech: about 2 cents a turn at three minutes, 3 at five, 5.5 at ten (projected). Three was the user's choice on 2026-11-13, once the brain was to remember for it. The limit used to be one fixed number, 12,000 tokens, which left less room for sound the longer the instructions were. The service cuts late: it lets a session run 30 to 45 seconds past the limit, so Stand holds between three and about five minutes. `STAND_CONTEXT_TOKENS=0` keeps everything for one run.
- **Fewer turns, tried and taken back.** For the evening of 2026-11-12 a pause had to last 1.5 seconds before Stand got a turn when it had no part in the exchange. That made one utterance of several people's sentences, and Stand then missed its own name about half the time (see "Who marks when someone is speaking"). Hearing came first: a turn now follows every 0.7 seconds of quiet, which is about three times as many turns.

What sessions cost, by the service's own count of tokens, which each run's `summary.json` has held since 2026-11-12 (`$BIN --probe spend` adds up the sessions kept here, by kind of run):

| | Length | Turns | Cost |
|---|---|---|---|
| The north-star script | 2.8 minutes | 16 | $0.21 |
| The discussion script | 1.5 minutes | 14 | $0.10 |
| The twelve-minute meeting | 11.3 minutes | 53 | $0.72 |
| The same on the evening's fewer turns (`--ends-after-when-out 1.5`) | 11.5 minutes | 13 | $0.22 |

Of the $0.72: $0.45 is the speech the model had in mind at each of its 53 turns, $0.24 is text (the instructions, about 4,000 tokens on every turn, and the prompter's sheets, which pile up until the oldest part of the session is dropped), and $0.03 is what Stand said and thought. In 42 of the 53 turns it decided to say nothing.

The 264 sessions before those counts were kept cost $20.00 between them, for 473 minutes. They had estimated themselves by the minute, as the price list reads, at $5.57. Rebuilt from their events, a turn at a time, they come to $21.29, and that rougher count is what `--probe spend` and the panel use for them.

For a real meeting this is a projection, not a measurement: the twelve-minute script, which is mostly silence, runs at $3.80 an hour, and an hour in which people talk most of the time would be about $5 to $10. Two things would bring that down and have not been tried: less text on every turn (shorter instructions for a discussion, and sheets that do not pile up), and a shorter word-for-word memory now that the prompter carries the thread. With no limit on what the model keeps, the same hour would be several times that.

### What Stand has to work with, besides what it hears

| | What it is | When Stand gets it | Where it lives |
|---|---|---|---|
| **The brief** | Your note about this meeting: who is there, what it is for, what to push for or avoid | Before it starts; it simply knows it | The panel's "For this meeting" box, kept in `brief.md` |
| **Notes** | Markdown and text files, in folders on this Mac or in GitHub repositories | When it is asked a fact it does not know: "let me check", then the answer | `context/`, plus whatever `brain.json` lists under `sources` |
| **What the brain can reach beyond the notes** | The web, other files on this Mac, and the tools of your MCP servers, which include this Mac's own Claude Code setup unless you turn that off | The same way, when the notes do not have the answer. It takes longer, and Stand says so | `web`, `mcpConfig`, `claudeCodeSetup` and `ask` in `brain.json` |
| **A note passed during the meeting** | A line you type while the meeting is going on | At once if it is silent; in its next pause if it is talking | The panel's text field |

The same binary runs checks from the command line:

```
BIN=mac/build/Stand.app/Contents/MacOS/Stand
$BIN --probe connect                          # silent: the Gemini connection
$BIN --probe selfhear                         # out loud: does Stand hear itself?
$BIN --probe otherapp                         # out loud: does Stand hear another app, as it must hear a call?
$BIN --probe tap                              # out loud, no voice model: how loud does another app's audio arrive?
$BIN --rehearse                               # the north-star script against the native session, no audio hardware
$BIN --rehearse --out-loud                    # the same through the real speakers, microphone and system audio
$BIN --rehearse poc/heckler/long.json         # a 25-minute meeting
$BIN --rehearse poc/heckler/discussion.json   # a discussion Stand sits in without giving a talk (see "Sitting in a discussion")
$BIN --probe doctor                           # silent: what this Mac gives Stand to work with
$BIN --probe spend                            # silent: what the sessions kept here cost, by kind of run
$BIN --probe marker runs/<a run>              # silent: play a run's room recording through the speech detector
$BIN --probe report                           # silent: that and the last session, as one zip to send
$BIN --probe brain "When is the next rehearsal?"   # silent: questions to the brain, timed
$BIN --probe sources                          # silent: where the notes come from, with linked repositories checked
$BIN --probe sources --add github.com/owner/repository   # add a source, as the panel does; --remove 2 takes the second one out
$BIN --probe panel                            # the real window for three seconds, driven with nobody at the keyboard
$BIN --render-panel /tmp/panels               # draw the panel to PNG files
```

`--raw` turns macOS echo cancellation off and `--no-system-audio` turns the system audio tap off, to show what each contributes.

### The brief

Write a few lines in the panel's **For this meeting** box before you press Start: who is there, what the meeting is for, what to push for and what to stay away from. Stand reads it with its instructions and acts on it without saying it was briefed. Where the brief and the talk plan differ, the brief wins. It is kept in `brief.md` and stays there until you change it, so look at it before each meeting.

To see one at work with no person involved (about two minutes):

```
$BIN --rehearse poc/heckler/brief.json --brief poc/heckler/brief.md
```

### Notes: folders and GitHub repositories

When someone asks Stand a fact it does not know, it says "let me check", a text model (the brain) finds the answer in the notes, and Stand says it in its own words.

Notes are Markdown and text files. A source is a folder, and whatever else is in it (code, configuration, data) the brain can search as well, in place, for what the notes do not say: how something works, what a setting is. Only the notes are ever sent to the model whole. Sources are:

- `context/` in this folder;
- any other folder on this Mac;
- a GitHub repository (github.com or GitHub Enterprise). Stand keeps a copy of the repository's notes and code in `linked/`, and checks for changes when the app opens, when a meeting starts, and every ten minutes. It uses GitHub's API, not git, the way Noteling links a team's tools.

Add a folder or a repository with the panel's **Notes…** link, or from the command line with `--probe sources --add`. Either writes to `brain.json`:

```json
"sources": [
  {"folder": "~/Documents/pilot-notes"},
  {"repo": "https://github.com/your-team/handbook", "branch": "main", "path": "docs", "token": "$HANDBOOK_TOKEN"}
]
```

`branch`, `path` (a folder inside the repository), `name` and `token` are optional. A browser address such as `github.com/your-team/handbook/tree/main/docs` gives the branch and the path by itself. A private repository needs nothing more if the GitHub CLI is signed in on this Mac: when GitHub will not show a repository without a token, Stand tries the CLI's login by itself. Without the CLI, give the source a `token`: `"$NAME"` for a secret in `.env` (a fine-grained token for that one repository, Contents: Read-only). Never write the token itself in `brain.json`.

The notes are read again whenever a file changes, so a file you save during a meeting is used from the next question on.

### The brain

**For this phase the brain is the Claude Code CLI on this Mac, kept open for the whole meeting and asked one thing after another. That is a compromise, not the design:** it was chosen on 2026-11-12 to get files, the web and MCP servers working now, and it makes Stand depend on one vendor's tool. What the brain should finally be is still open.

What it may do. The rule for this phase is to ask you as little as possible: useful and a little creepy, before safe and annoying.

- **It reads and searches the folders you gave it under Notes**, whatever is in them, with its own tools. Each folder is a boundary: what is in it is in reach, in place, with nothing copied.
- **It reads** any other file on this Mac that a question names.
- **It uses the web**, when `web` is on and the notes do not have the answer. It never searches the web about Stand, the people in the meeting or their own projects.
- **It uses the tools of the MCP servers it has**: this Mac's own Claude Code setup, unless `claudeCodeSetup` is turned off, and any file named by `mcpConfig`.
- **It asks you first only before a tool whose name says it cannot be undone**: send, delete, cancel, pay, publish and the like (`prompts/ask-before.txt` has the words). A line appears in the panel with **Allow** and **No** for 20 seconds, and no answer is a no. Refused, Stand says it cannot do that just now, and nothing about having been refused. `"ask": "never"` removes even this; `"ask": "always"` asks before everything beyond the notes and a web search.
- **Two things it refuses without asking**, because a key spoken into a meeting cannot be taken back: a file that looks like it holds secrets (`.env`, keys, shell profiles and so on), wherever it is, and searching inside files outside its folders, since a search reads hidden files too. To make a folder searchable, add it under Notes. Inside its folders the files that hold secrets by their names are kept from it by Claude Code's own rules, which its search obeys; a key written inside an ordinary file is not caught that way, and it is told never to give one out.
- It has no tool that runs a command or changes a file.

What it reaches for shows in the panel's status line while it happens, and is in the run's transcript afterwards.

An answer from the notes takes about a second. If the brain has not answered after 5 seconds, Stand says it is taking a moment and carries on with the meeting; the answer reaches it when it comes, the way a note from you does, and Stand then tells the person who asked. After 60 seconds it gives up and says it could not find it.

`brain.json` says how the brain is reached and what it may reach. In the repository it is yours and is not checked in: until there is one, the settings are those in `mac/Resources/brain.default.json`, which is the file to copy to the top of the project as `brain.json` when you want to change one. The first setting names are Noteling's:

| Setting | What it does |
|---|---|
| `connectionMode` | `claudeCode` (the kept-open Claude Code CLI, using its own login), `api` (one request to the Messages API for each question: notes only, no web, no tools), or `auto`: the API when `ANTHROPIC_API_KEY` or `apiBaseURL` is set, the CLI otherwise |
| `apiBaseURL`, `apiHeaders` | For `api`, your own gateway: `/v1/messages` is added to the base URL, and a header value written `$NAME` is read from `.env` |
| `model`, `effort` | `claude-sonnet-5-5` at `low` unless changed |
| `prepareModel`, `prepareEffort` | for preparing a talk before a meeting: `claude-opus-5-5` at `high` unless changed. Nobody is waiting then, and what it writes is said in front of people |
| `contextFolder` | The project's own notes folder; `context` unless changed |
| `sources` | More folders and GitHub repositories, as above |
| `docsStuffLimitChars` | Notes up to this size (400,000 characters unless changed) are put in the brain's prompt. Bigger, and it reads files with its tools, which is slower |
| `web` | `true` unless changed: the brain may search the web |
| `mcpConfig` | A file of MCP servers for the brain, in Claude Code's own format (`{"mcpServers": {…}}`). `${STAND_ROOT}` in it stands for this folder |
| `claudeCodeSetup` | `true` unless changed: this Mac's whole Claude Code setup comes into the brain, with the MCP servers it has and its settings. `false` leaves the brain with only what `brain.json` gives it |
| `ask` | `irreversible` unless changed: see above. `never` or `always` |
| `allowWithoutAsking` | Tools that never ask, even with such a word in their name, by Claude Code's names for them: `mcp__orders__cancel_order` |

How long the brain takes, measured on 2026-11-12 with `claude-sonnet-5-5` at low effort:

| | A process for each question, as it was until today | One process kept open, as it is now |
|---|---|---|
| A few small notes | 1.4 to 2.1 s | 0.8 to 0.9 s |
| 305,000 characters of notes, read with file tools | 2.8 to 6.4 s | 2.2 to 4.3 s |
| A tool from an MCP server, once allowed | | about 2 s |
| A web search | | 6 to 9 s |

Sending 305,000 characters of notes whole took 1.9 to 2.2 seconds with a process for each question, which is why notes up to 400,000 characters go in the prompt. `claude-opus-5-5` was slower that morning (2.8 to 4.8 seconds on small notes) and `claude-haiku-5-5` faster (1.3 to 1.5) but wrong once in three on the larger notes.

Not run: the Messages API connection, direct or through a gateway, which is written and compiles. No real private repository has been fetched. Claude Code's skills are not given to the brain.

To see lookups with no person involved (about two minutes each):

```
# one folder of notes
STAND_CONTEXT=poc/heckler/context $BIN --rehearse poc/heckler/lookup.json --talk poc/heckler/short-talk.md
# two folders and a public GitHub repository
STAND_BRAIN=poc/heckler/sources-brain.json $BIN --rehearse poc/heckler/lookup-sources.json --talk poc/heckler/short-talk.md
# the notes, a tool from a test MCP server, and the web
STAND_BRAIN=poc/heckler/operator-brain.json $BIN --rehearse poc/heckler/lookup-operator.json --talk poc/heckler/short-talk.md
# the brain set to ask before everything, with nobody saying yes
STAND_BRAIN=poc/heckler/operator-brain-ask.json $BIN --rehearse poc/heckler/lookup-operator-no.json --talk poc/heckler/short-talk.md
# the brain alone, several questions to one process: looking does not ask, cancelling does (--allow says yes)
STAND_BRAIN=poc/heckler/operator-brain.json $BIN --probe brain "Where has the Juniper order got to?" "Cancel the Harbour order." --allow
```

A rehearsal leaves this Mac's own Claude Code setup out of the brain, so that scripted questions do not go looking in your mail and calendar. `--own-setup` brings it in.

`STAND_BRAIN` reads the brain's settings from another file for one run. `STAND_CONTEXT` makes one folder the only notes for one run.

### Passing Stand a note during a meeting

Type in the panel's text field and press Return. Only Stand gets the note; the audience hears nothing of it. Escape gives up, and either way the keyboard goes back to the app you were in.

- A note that asks for something to be said or done ("tell them we have five minutes left", "wrap up") is acted on. A note that only tells Stand something ("the budget is forty thousand") is kept in mind, and Stand says nothing.
- If Stand is silent, it gets the note at once.
- If Stand is talking, it gets the note in its next pause, as a person would glance at one between sentences, and carries on from where it paused.
- If someone is asking Stand a question, it gets the note at once and answers when they have finished.
- In a discussion, where the people speaking are mostly not speaking to Stand, a note waits for them to pause, and is not cut into what Stand itself is saying.

The window is left out of screen sharing unless you turn that off in the Stand menu, because the brief and the notes are private. That has not been checked against a call's screen sharing yet.

To see notes passed with no person involved:

```
$BIN --rehearse poc/heckler/notes-passed.json                                        # one of each kind, two minutes
$BIN --rehearse poc/heckler/notes-mid-talk.json                                      # eight notes during the talk
$BIN --rehearse poc/heckler/notes-idle.json --talk poc/heckler/short-talk.md         # to say now, or only to know
$BIN --rehearse poc/heckler/notes-while-asked.json --talk poc/heckler/short-talk.md  # passed while someone is asking
```

### Stand asking you

The other direction. When someone asks Stand for something only you can say (what you think, what you will agree to, whether you can do Thursday), or a fact that matters could not be found, Stand does not guess and does not just say it doesn't know:

1. It says so out loud: "I'd have to check that with Morgan. I'll come back to you." The meeting goes on.
2. Its question appears in the panel, in a yellow box, worded for you: "Can you do the Thursday instead of the Wednesday for the workshop?" Control-Option-N puts the keyboard in the answer field.
3. You type an answer and press Return. Stand passes it on at the next pause, as coming from you: "Morgan says Thursday works, but only after two."
4. **No answer** tells Stand you have none, and it says it could not get one.

It asks you nothing it already knows from the brief or from a note, looks facts up in the notes as before, and does not trouble you with small things nobody needs.

Whether it says honestly that it is checking with you, or stalls without saying why, is a matter of wording: `prompts/voice-ask-your-human.md`.

```
STAND_CONTEXT=poc/heckler/context $BIN --rehearse poc/heckler/discussion-ask.json   # one question answered after nine seconds, one with no answer
```

In the last five runs of that script (2026-11-12, scripted voices and a scripted human) every line went as expected: both questions reached the human, Stand said it would check, passed the answer on when it came, said it had none for the other, still looked up a fact from the notes, and did not ask about the weather. The first three runs showed two faults, since fixed: an answer handed to Stand while other people were talking was never said, and once it put the question to its human without a word to the meeting.

## The proof of concept

`poc/` is a throwaway rig for the first test. A voice model gives the talk, hears the room, and speaks back directly, with no transcript in between. The rig is a web page (microphone and speaker) plus a small local server. The desktop app comes after this test passes.

### Set up

1. Copy `.env.example` to `.env` and fill in `GEMINI_API_KEY` (from Google AI Studio), `OPENAI_API_KEY`, or both.
2. Install: `cd poc && npm install`

### Talk to it

```
cd poc
npm start
```

Open http://localhost:5177 in Chrome, choose a voice model, press **Start the talk**, and interrupt it out loud. Use headphones if it keeps cutting itself off.

Stop the server with Ctrl+C in its terminal, or with `npm run stop` from any terminal. Ctrl+Z only pauses it, and the paused server keeps the port.

### Run the scripted audience

```
npm run heckler -- --provider gemini
```

This plays the north-star script at Stand with no person involved: three interruptions, one "mm-hm" it should talk through, then closing questions. It takes about ten minutes and ends with a `report.md`.

### Check the rig without a key

```
npm run heckler -- --provider mock    # the audience script against a fake Stand
npm run smoke                         # the page in headless Chrome
```

### What a run leaves behind

Every session is saved in `poc/runs/<time>-<model>-<kind>/`:

| File | What it is |
|---|---|
| `recording.wav` | Stand and the room on one timeline |
| `transcript.md` | What was said, with interruptions and nudges marked |
| `report.md` | Scripted runs only: how fast Stand stopped and replied, plus the pass test |
| `summary.json` | Length, counts and a rough cost |
| `instructions.md` | The exact instructions Stand ran on |

### Where behaviour lives

| To change | Edit |
|---|---|
| What Stand knows about itself | `identity/stand.md` |
| How it sounds | `identity/character.md` |
| The talk | `talks/introducing-stand.md` |
| How it presents and handles interruptions | `prompts/presenter.md` |
| When it looks something up, and what it says meanwhile | `prompts/voice-look-it-up.md`, `prompts/tool-look-it-up.txt` |
| How the brain answers, and what it is told it may use | `prompts/brain-operator.md`, `prompts/brain-abilities.txt` (`prompts/brain.md` for the Messages API) |
| What Stand says when an answer is slow, and how a late answer reaches it | `prompts/lookup-still-looking.txt`, `prompts/lookup-late-answer.txt`, `prompts/note-from-brain.txt` |
| How it treats the brief | `prompts/voice-brief.md` |
| How it treats a note passed during the meeting | `prompts/stage-manager-note*.txt`, `prompts/tool-nothing-to-say.txt` |
| What the stage manager tells it | `prompts/stage-manager-*.txt` |
| What the scripted audience says, and when | `poc/heckler/north-star.json` |

### Other checks

```
npm run heckler -- --provider gemini --script heckler/noise.json     # one minute: what stops Stand
npm run heckler -- --provider gemini --script heckler/junk.json      # one minute: recovery from an echo and a howl
STAND_TALK=poc/heckler/short-talk.md npm run heckler -- --provider gemini --script heckler/ending.json   # one minute: the end of a talk
node src/listen.js runs/<run>/stand.wav --from 30 --to 32            # ask a model what a stretch of audio says
```

### Status (2026-11-14, in the open)

Stand is open source since today, at `github.com/noteling/stand`, under Apache 2.0. The user asked what keeping it closed was worth, and asked for an honest answer: "not open source will create friction for us". The answer was little.

- **Why open:** the idea is no secret (meeting agents that speak are on sale, and in open source, already), the code took three days, and a packaged app carries every prompt as a plain text file. What publishing gives an app that listens to meetings and reads internal code is that people can read what it does.
- **Kept out, because it is the person's own:** keys, the brief, `brain.json`, what is in `context/`, every talk Stand prepares, and every session with its recording (see "What is not in the repository" at the end). Before today, a talk prepared about a company's system would have gone into the first commit after it.
- **Changed for it:** a `.gitignore` line that brings a file back (`!…`) is now followed when a folder's notes are walked. That keeps Stand's own two talks among the notes where this repository is the system under test.
- **Checked:** a copy cloned from the first commit builds with `mac/scripts/build.sh debug` in 36 seconds, says what it has to work with, adds a folder of notes, and tells a person with no key where to put one; git ignores the settings it writes. On a made-up folder, Stand's walk keeps the same files git keeps. With this repository as the system, the brain has the same 96 notes as before, answered a question from the code in 4.8 seconds, and was refused `brain.json`. The JavaScript rig's check without a key (`npm ci`, then the scripted audience against a fake Stand) ran from the clone in 70 seconds.
- **Not checked:** a session with the voice model since these changes. Nothing on the live path was touched. Two tests cannot run from a clone, because the recording they play is not published.

### Status (2026-11-13, whose voice)

The user asked whether Stand's voice is configurable: "I mean like whose voice to use". It was not; it had been Kore since the first day.

- **Built:** **Voice** in the panel, a menu of the thirty voices the live model takes, with **Hear it** (see "Whose voice" above); `--probe voice`, `--voice` on a rehearsal, `STAND_VOICE` for any run.
- **Found:** the live model takes those thirty and no others, and does not say so. A name it does not know gets Zephyr's voice. A person's own voice is not on offer for the live model with a key such as Stand's.
- **Checked, without a sound being made:** the menu's layout; samples fetched in two voices, and a made-up name refused by Stand; the panel's player fed a sample at no volume (first sound after 1.0 s, all of it played); **Hear it** pressed on the panel's own controller at no volume (`--probe voice --as-the-panel`: the sample plays as it arrives, stops when another voice is chosen, and is kept for the next press); the packaged app finding the list inside itself; the north-star talk in Charon's voice (8 of 8 sections, every question answered, 2:07 of speech where Kore's runs had 2:09 to 2:34), a man's voice by pitch and by a listening model; the half-minute discussion test in the usual voice, 3 of 3.
- **Not known:** how any of the thirty sounds, to a person. Whether **Hear it** sounds right through the speakers. What the menu looks like open.

About 40 cents: 24 for the two rehearsals, the rest for some fifty one-sentence samples and a listening model.

### Status (2026-11-13, a room that reacts)

The user gave the introduction talk to a friend, the first time Stand has had more than one person in the room, and said afterwards: "even my laugh will cut it… it's kinda dumb in terms of it's not even reacting to the laugh". In 100 seconds Stand was stopped seven times: once by a question to it, twice by laughter, and four times by the two of them talking to each other.

- **Why a laugh stops it.** Stand's voice model cannot listen while it speaks. Being stopped is the only way it hears anything.
- **A short sound no longer stops it.** In a talk, a sound counts as someone speaking once 0.6 seconds of it has been loud. A cough, an "mm", a laugh of a second or two pass, and Stand keeps talking. The sound is kept meanwhile, so a real question arrives whole; Stand stops about a second after it begins, where it stopped after a fifth of a second.
- **A long laugh, or people talking to each other, still stops it.** What changed is how it comes back: from the words where it stopped, with no "back to where I was" unless it answered someone.
- **Tried on the user's own recording** (`talk-room.json` plays its laughter and talk into a talk), 9 runs: the short laugh never stopped Stand; after the long one it went on without a bridge every time; after the two people's talk it went on without a word in 5 runs and answered or put off the question it had overheard in 4; a real question was heard whole and answered every time.
- **Not got:** Stand does not laugh along or say a word about a laugh, whatever the wording.
- **Found afterwards: that is not deafness.** Asked what the sound was, the voice model names the laugh in 8 runs of 10 when it is given a plain listener's role, and in 1 of 10 as Stand, where it answers "I do not have a description of that sound". It tells a second speaker from the first in 9 of 10 against 0. Stand's own role does this: it says that what Stand knows is what is written, and never to guess beyond it. One added line ("What you hear is yours to say…") brought the laugh to 9 of 10. It is written down and not put in: it has only been tried on a direct question, and not against the scripts that catch Stand speaking when it should not. CLAUDE.md, "What the voice model itself hears", has the numbers and the probe.
- **Not known:** how it sounds. Scripted and replayed sound only.

### Status (2026-11-13, afternoon: a talk prepared from documents and code)

The short-term goal, set by the user that day: Stand introduces one of their company's internal systems in a real meeting, from a talk its brain prepared out of that system's documents and code, and answers questions by looking them up. Everything below was tried on Stand's own repository (84 documents, 89 files of code), with scripted voices only.

- **A folder is the boundary, and the brain greps it in place.** The user's design, which replaced a filtered copy I had built first. Questions only the code answers took 3 to 5 seconds, and questions the documents answer 1 to 2. Asked to search outside its folders, the brain was refused. A planted key in a hidden `.env` was not found by its search, not read when asked for by path, and not listed; neither were `keys.json` and `secrets.json`. A password written inside an ordinary configuration file was found (by file name only, as asked): names are what is checked, not contents.
- **The brain prepares the talk.** From three lines about the meeting it wrote a plan in one to two and a half minutes: fifteen sections, about 1,800 words of points, and seventeen facts to have ready. Its figures were checked against the code where I looked (the speech detector's thresholds, the limits, the timings) and were right. It read the code as well as the documents: the plan describes the section-at-a-time handover from a comment written an hour earlier.
- **A ten-minute talk** (`system-talk.json`, 2 runs with a fifteen-section plan). Fifteen sections in order, none twice, the floor opened at the end, 9 minutes of speech for the 10 asked. Six interruptions on the way. Someone who gave a name and a job in the first minute and asked for something "at the end" was named, with the answer, nine minutes later: the voice model itself holds three.
- **Questions during it:** a fact from the plan at once; one from the notes in about a second; one that takes a search of the folder in 3 to 7 seconds, after "let me check"; something that is nowhere, said to be nowhere.
- **Found on the way, and what was done:**
  - Keeping its own place over ten minutes, Stand gave half a section twice and ran its last three sections into one. The stage manager now keeps the place and hands over one section at a time.
  - Stand says little more than the plan gives it, and fast: a plan written as "points, not the speech" gave five minutes where ten were asked. The brain now writes to Stand's measured pace.
  - Told after an interruption which points "had not been heard", Stand repeated points it had only shortened. It is now given only the points after the last one it plainly made.
- **Still wrong, or not known:**
  - A scripted "mm-hm" was answered as if it were a question in 1 run of 4 ("That isn't something I have information on"). The service heard it as words.
  - Asked a general question after a short talk (the latest version of Swift), Stand looked it up in 1 run of 4 today, against 2 of 4 with the morning's wording and 9 of 14 the day before. Too few to tell apart.
  - The pause between sections is a little over a second. Whether that sounds like a breath or like a hitch is for a listener to say.
  - A talk about a code base far bigger than Stand's own. The time to prepare and the time to answer will both grow, and neither has been measured.
- **What it cost:** a ten-minute talk with questions is about $0.80; an hour at that rate is about $4.50.

### Status (2026-11-13, the brain as Stand's memory)

The user's direction that day: make the voice model's part smaller still. It keeps three minutes; the brain remembers the rest and feeds it in. Built for talks, where nothing kept the thread before. Scripted voices only.

- **The test** (`talk-memory.json`): early in the north-star talk someone says "I'm Priya, from the billing team. At the end, could you tell us whether it works on Windows?", someone else takes the talk off course later, and the closing questions ask what was owed and who asked. The voice model is set to hold about one minute, so the exchange is gone from it by then.
  - With the brain's memory, 2 runs of 2: "Priya asked whether Stand works on Windows, but I don't have that information yet" and "Yes, you are Priya from the billing team", both after the model's own memory had been cut. All eight sections in order, none twice.
  - Without it (`--no-prompter`, 1 run): it answered the first question while it still held the exchange, was cut ten seconds later, and to the second said "I don't have a record of your name or team".
- **The north-star talk on the new defaults** (three minutes, the brain following): 1 run after the fix below, every question answered within two seconds, the sections in order, the floor opened. The main discussion 11 of 11 and the lookup talk as before, 1 run each.
- **Found and fixed on the way:** the sheet was passed to Stand in the instant a question ended, and Stand then did not answer the question for 26 seconds. In a talk the sheet now waits for Stand's own speech to run out.
- **Not built that morning, built the same afternoon (see above):** handing the talk to the voice model a section at a time, with the place kept by the stage manager and not by the brain.
- **Not run:** a talk long enough for three minutes to matter at its real setting (`long.json` is 25 minutes); anything by voice. `identity/stand.md` still says the brain follows a discussion and does not mention talks.

### Status (2026-11-13, the first discussion by voice)

The first two sessions in which a person spoke to Stand in a discussion, 18 and 36 seconds long, and what they showed.

- **Found: Stand announced a fact from its brief that nobody had asked for.** The brief was the one line "team has 19 people". The person opened a meeting about a team outing and asked "Stand, you there?", and Stand answered "The team has 19 people." The prompter had not handed it anything yet: the voice model did this by itself. In the session before, with the brief "The pilot had 14 people", it had answered "Is everyone okay with that?" with the bare sentence "The pilot had 14 people."
- **Reproduced with scripted voices** (`discussion-fact.json`). The scripted "Stand, you there?" was answered properly every time, so in the live session the question was probably misheard as well (the service's transcript has "I'll send you there"). What did reproduce: after "Let's go with bowling on Thursday evening", with no number mentioned by anyone, Stand said things like "Just a reminder, the team has 19 people, so we will need to ensure enough bowling lanes are reserved", in 4 runs of 4. With the usual 0.9 seconds between speakers the same remark collided with the next person, was not played, and the run passed. The script leaves four seconds there.
- **Changed, in the wording only, apart from one label:**
  - The brief's framing says a fact in the note is to know and not to announce, and that a note which asks Stand to watch for nothing leaves it there to listen and to answer.
  - The role ties "what you are there for" to what the note asks for, tells Stand that knowing a fact about the subject is no reason to speak, and tells it to answer what it was asked and only that.
  - The prompter gives the facts on its sheet without saying why they matter ("The team has 19 people, which matters for group size at bowling" had come back from Stand almost word for word).
  - The sheet reaches Stand labelled "Facts to have ready", where it said "Facts that bear on what is being discussed now", and the message carrying it says that a fact in front of Stand is no reason to speak.
- **After:** the unasked remark came in 1 run of 8, where it had come in 4 of 4. It is not gone. In the other 7 Stand said "Yes, I am here", kept quiet through the talk about the outing, corrected "lanes for twenty-five" with the nineteen, and answered "how many of us are there?"
- **Nothing else moved** on the final wording: the main script 11 of 11 twice, the prompter script 6 of 6 twice (the correction still made), the pushback script 9 of 9, the no-brief script 6 of 6 three times.
- **Tried and dropped:** a line telling Stand how to word a correction ("say both what you heard and what you have"). It made the corrections read better, and it made Stand look for things to correct: on the no-brief script it looked up a date and corrected two people who were deciding to change it, in 2 runs of 2.
- **A question left hanging: the rule stays** (the user's decision that morning). After three seconds in which nobody answers a question put to "you", Stand takes it, and it does not first ask whether it was meant. On the new script (`discussion-hanging.json`) it took such a question in 10 runs of 10.
- **Fixed with it:** when the person who was asked answers after a few seconds, the prompter's point ("that question was probably for you") used to reach Stand at the next pause all the same, and Stand answered the question again: 4 runs of 4 in which the path came up. A point about a silence is now dropped once someone else speaks: 3 of 3 quiet.
- **Found: the voice model itself took a question between two other people for its own.** When one scripted person plainly asked the other "Which one would you go for?", Stand answered at once, before they could, in 17 runs of 24: "I have no view on which room you choose." Scripts with under a second between speakers could never have shown it.
- **The user's rule, given in answer to that: Stand speaks when it is contributing.** In their words: "bringing in new info, contribute to the call, gain visibility (if it's part of owner's goal), not speak to make the situation more awkward". It is now the first thing the role says about speaking, and the prompter's rules open with it. What follows from it in the wording:
  - Asked by name, Stand always answers. A question with no name on it, between people who were talking with each other, is theirs: Stand takes it only if it has something to add, and never to say that it has no view.
  - The prompter no longer hands Stand a hanging question that belongs to other people's exchange when the notes and the brief have nothing on it. A question nobody answers that could be anyone's ("anything else from you?") is still handed over, as the user decided.
  - A brief can ask Stand outright to make something known ("I want the team to know the sign-up page went live"). Stand brings that up when the subject comes, or when asked whether there is anything else. What a brief only tells it to watch for waits for its moment.
- **After, on the script with the two people:** Stand left their question alone in 5 runs of 6 on the final wording, and in 20 of 24 across the wordings tried. On the make-known script it said the one thing it was asked to make known, once, in 5 runs of 5, and never the things it was only to watch for. The no-brief script 6 of 6 four times; main 11 of 11 twice; prompter 6 of 6 twice; pushback 9 of 9; names 8 of 8; its name after another sentence 3 of 3 twice.
- **Side effect, not fixed:** asked "Anything else from you before we finish?" with nothing to make known, Stand should say no. On the final wording it used the question to bring up something its brief had only told it to watch for in 4 runs of 6 ("I must remind everyone that the next session cannot be earlier than 19 November"), where it had done so in 1 run of 10 before the rule. The fact nobody asked for (the first finding above) still came in 1 run of 3.
- **Not done:** the DMG of 2026-11-12 does not have these changes.

### Status (2026-11-12, night)

The prompter, and what building it showed about how Stand hears. Scripted voices only, as before: nothing here has been heard through a microphone or tried by a person. The app in `mac/build` and the newest DMG have all of it.

- **The prompter** (see "The prompter"). On its script, someone says about twenty people came on Tuesday and orders lunch for twenty, and the notes say fourteen.
  - With the prompter Stand corrected the figure without being asked and answered the two questions that followed, 30 lines of 30 in the last 5 runs. Without it (2 runs) the wrong figure stood: Stand cannot see its notes and had no reason to look.
  - In the main discussion script Stand now answers the attendance question from its sheet, with no "let me check" and no lookup, in 7 runs of 7.
  - In a five-minute meeting run on a small memory, it answered three questions about the first half minute from its sheet (21 lines of 21 in the last run; 19 to 21 in the four before it).
- **What went wrong on the way, and is fixed:**
  - The prompter brought back a point Stand had been overruled on, and Stand made it again. The prompter is now told that such a point is finished, Stand is told so where it decides whether to speak, and the script checks that the date is not mentioned again. In the 9 runs since it was never heard again. In 2 of the first 4 Stand began to say it and gave way to the next speaker; in the 5 on the present wording it did not begin.
  - It raised a point on a guess ("the Thursday" must be before the 19th), and Stand made that point before passing on a note from its human. It now raises only what the transcript shows plainly, and a note from the human goes first.
  - Told that it could let a point go, Stand let the correction go in 2 runs of 2 once it had already decided several times to say nothing. It is now told to act on a point unless it has made it already and been heard, or the meeting has decided against it.
  - A hold on Stand's speech, left over from an earlier collision, swallowed a later remark without telling Stand, which then would not repeat it. The hold now ends with the turn.
  - For a few runs Stand was told that the last sentence before a pause is the one that matters. It answered the closing question in 0 runs of 2 with that line and 35 of 38 without it, so the line is gone.
- **How Stand hears a discussion changed twice** (see "Who marks when someone is speaking"): each sentence is an utterance of its own, and a new utterance waits for the model's turn on the last one. "Stand, anything else from you before we finish?", a second after someone else's sentence: 22 runs of 22, where the two earlier ways gave 21 of 43 and 6 of 17. The service's transcript, which the prompter reads, used to lose between a seventh and a third of the lines in a script. In the 47 discussion runs since, it has all 466 lines.
- **Every script since those two changes** (50 runs, 3 of them the talk):

  | Script | Runs | Lines as expected |
  |---|---|---|
  | `discussion.json` | 7 | 77 of 77 |
  | `discussion-long.json` (twelve minutes) | 1 | 51 of 51 |
  | `discussion-tail.json` | 8 | 24 of 24 |
  | `discussion-banter.json` | 2 | 26 of 26 |
  | `discussion-notes.json` | 4 | 36 of 36 |
  | `discussion-prompter.json` | 7 | 40 of 42 |
  | `discussion-pushback.json` | 9 | 79 of 81 |
  | `discussion-pauses.json` | 3 | 15 of 15 |
  | `discussion-names.json` | 2 | 16 of 16 |
  | `discussion-ask.json` | 2 | 20 of 20 |
  | `discussion-open.json` | 1 | 6 of 6 |
  | `discussion-memory.json` | 1 | 21 of 21 |

  - It stayed quiet after every line that was not for it, 266 of 266.
  - The two misses on the prompter script are the correction Stand let go, before it was told to act on a point (above).
  - The two on the pushback script: cut off after "My name comes from JoJo's Bizarre" and asked to go on, Stand went on from there, as it is told to, and the script wanted the word "JoJo" again. The script now accepts either.
  - The talk was run once on the same code (the north-star script, and two of the note scripts): as before.
- **The price is turns.** The twelve-minute meeting took 53 turns of the model and cost $0.72, against 13 and $0.22 the evening before. See "What a session costs".
- **New since these changes, and worth watching for:** Stand now gets a turn after every sentence, so it starts to speak more often just as the next person does. Each time it gave way, none of it was heard, and it made its point after that person had finished (5 times in the twelve-minute run). The scripts leave exactly 0.9 seconds between people, which is the worst case for this; with people it will be different, and nobody has heard it.
- **Not checked:** any of it with people or out loud; a real meeting's worth of the prompter (the longest run is twelve minutes); what the prompter does with a transcript of real, overlapping speech; a question left hanging that was meant for someone else and took them more than three seconds to answer.

### Status (2026-11-12, evening)

Two things below were changed later that night: the fewer turns were taken back, and the thread of the meeting became the prompter's sheet.

After the Gemini account had credit again, and with every batch priced first: 40 sessions, $2.93 by the service's own counts. Still scripted voices only.

- **The speech detector's present form has now run in sessions.** The discussion script went 11 of 11 in 6 runs of 7 (the seventh missed "anything else from you?"), and the north-star script heard every line whole in 3 of 3. In one of those three, Stand stopped for twelve seconds in the middle of the talk: its reply to "carry on" was one sentence, which the stage manager took for waiting on purpose. That has happened once in 20 north-star runs and is not new.
- **Cut off as it starts to speak, Stand makes its point when the other person has finished.** It did in 6 runs of 6 with the present wording, after 2 misses in 9 runs with the wording before it. On the way, a wording that told it more firmly to say what was not heard made it repeat a point it had been overruled on, because the words quoted back to it ran into its previous remark. They are now its present remark's only.
- **The memory limit.** The twelve-minute meeting went 51 of 51 in 2 runs of 2 keeping at most 8,000 tokens, for $0.16 against $0.23 with nothing dropped. Keeping only 4,000, which is barely more than the instructions, it lost a question between asking its brain and getting the answer. The limit now in force, 12,000, has not been reached by any script.
- **The thread of the meeting.** In a five-minute meeting run on a small memory, Stand was asked three things about its first half minute. With the thread it answered all three in 2 runs of 2. Without it, none in 2 runs of 2: it said it did not know, or answered from the last thing it had heard.
- **Fewer turns.** With the longer pause when Stand is not part of the exchange, the twelve-minute meeting took 14 or 15 turns of the model. Of four such runs, two went 51 of 51 and two 50 of 51. The line missed both times is "Stand, anything else from you before we finish?", said straight after two other people: it goes unanswered about one time in ten in the short script and more often here.
- **A note passed just after someone stops speaking** was once taken in with what they had said, and Stand said nothing. The room's still-open utterance is now ended first: 9 of 9 lines in 3 runs of 3.
- **Not checked:** a meeting long enough to reach the 12,000 limit; any of it with people or out loud. `docs/uat.md` is the list of what only a person can check.

### Status (2026-11-12, discussions)

Added in the afternoon of 2026-11-12. Checked with scripted voices only: no person has spoken to Stand in a discussion, and none of this has been run out loud.

- **Stand sits in a discussion.** After each line of a script, Stand either speaks or does not, and the script says which is right and, where it is known, what Stand has to say.

  | Script | Runs | Lines as expected |
  |---|---|---|
  | `discussion.json` | 10 | 109 of 110 |
  | `discussion-long.json` (twelve minutes) | 2 | 102 of 102 |
  | `discussion-banter.json` | 4 | 52 of 52 |
  | `discussion-pushback.json` | 3 | 24 of 24 |
  | `discussion-notes.json` | 3 | 27 of 27 |
  | `discussion-open.json` | 3 | 18 of 18 |
  | `discussion-names.json` | 3 | 24 of 24 |
  | `discussion-pauses.json` | 4 | 20 of 20 |
  | `discussion-silence.json` | 1 | 3 of 3 |

  - Across these it stayed quiet after every line that was not for it, 270 of 270, among them every ordinary use of the word "stand".
  - Of the 110 lines it should have spoken after, it did after 109, saying what the script names. The miss: asked "anything else from you before we finish?", it said nothing, once in ten.
  - Both twelve-minute runs were counted before the scripts checked what Stand says. Read afterwards, one of them has Stand answer the attendance question with "I don't have the exact number" where it should have looked it up.
  - These are each script's most recent runs, and the wording changed several times during the afternoon. Only the banter and pushback runs are on the final wording (the brain tells Stand what the notes cover, and Stand answers whatever it is asked directly): the Gemini credit ran out before the others could be run again. The others are one to three small changes behind it.
- **What the earlier wordings got wrong,** and the tables above do not show:
  - Asked "anything else from you?", Stand said nothing in 33 runs of 37: it called its tool for saying nothing, as if that were the answer. Told that a question put to it always gets a spoken answer, it answered in 27 of 28, with "No, nothing more from me" or the like.
  - Asked for a fact after a long stretch of unrelated talk, it said "I don't know" without looking it up, in 9 runs of 12. With the brain's outline of the notes in its instructions, it gave the fact in 4 of 4.
  - It passed on "Tell them I will bring the name badges" as "I will bring the name badges".
  - Cut off and then asked to go on, it once said the question "isn't the point of today's discussion".
- **Stand marks who is speaking**, for talks as well.
  - North-star script, 3 runs each way: with Stand marking speech, all seven of the audience's lines were heard whole. With the service marking it, the off-topic question lost its first words and the goodbye was garbled in all 3.
  - Lookup script, 3 runs each way: whole questions in 3 of 3 against fragments ("What was the budget for the", "When is the next") in 2 of 3, and the goodbye answered in 3 of 3 against 1 of 3.
  - The other talk scripts were each run once with Stand marking speech (junk, noise, ending, the four note scripts, the brief, the three brain scripts, the 21-minute session) and behaved as before, as far as their reports show. Nobody listened to them.
  - With a steady noise under the room at two levels, and with Stand's own voice echoed back at a tenth of its loudness, the discussion script went 11 of 11 in all 6 runs.
  - Run over the recordings of two earlier sessions that used the real microphone: in the scripted one it marked the seven audience lines and nothing else; in a person's own session it marked their two interruptions, each in two pieces, and one short sound at the start that is not accounted for. Between voices, and while Stand itself spoke, the microphone's level was about 1 out of 32768.
- **The brain tells Stand what the notes cover** before a meeting, in a sentence or two (1.3 seconds here). In the talk-mode lookup script Stand then looked up exactly the three questions that needed it, in 3 runs of 3.
- **Changed after the last runs, and checked without a session:** the speech detector's present form (see "Who marks when someone is speaking"); a note in a discussion now waits until Stand has finished speaking; a session that fails to start no longer leaves the brain's program running. These came out of an independent review of the day's code.
- **Known weak points:** if a lookup's answer comes back while someone is speaking, Stand may talk over them, and their carrying on would not stop it; a voice quieter than the detector's bar does not reach the service at all; a pause of 0.7 seconds in the middle of a sentence gives Stand a turn.
- **Not checked:** any of this with people, or out loud; the connection being replaced while someone is mid-sentence (the 21-minute session never needed a new connection); the brain's program being found on a Mac where it is not in the first place looked; the problem report on another Mac.
- **Not built:** Stand correcting a fact nobody asked it about when the fact is only in its notes (it would have to check quietly, by itself); anything that tells voices apart.

### Status (2026-11-12)

What was added earlier on 2026-11-12, all of it checked with the scripted audience and none of it yet by a person in a call:

- **Notes come from folders and GitHub repositories.** A public repository's notes were copied in 0.7 to 0.9 seconds the first time, and a check with nothing new took 0.1. In the scripted run Stand answered by voice from the project's folder, a second folder and a repository, and said what it could not find. With `claude-sonnet-5-5` the brain took 1.4 to 2.1 seconds an answer in sessions, and once 3.5.
- **The brief works.** In nine runs Stand greeted the two people the brief named, left out the part of the talk it was told to leave out, and answered the price and pilot-date questions from the brief, every time. Asked directly about the part it had left out, it at first said it did not know, which is false. The brief's own instructions were reworded three times for that: it answered in one run of two, then two of three, then three of three.
- **Notes passed during a meeting work.**
  - Passed while Stand was silent: 21 of 21 that asked for something were said, within 0.6 to 1.0 seconds, and 17 of 17 that only told it something drew no sound.
  - Passed while Stand was talking, in the last three runs: 9 notes reached it mid-speech, each in a pause. The gap was 0.7 to 0.9 seconds in eight and 2.3 in one, and a model listening to the recording heard nothing said twice and nothing skipped. Twelve more arrived just as a section ended, and reached it then.
  - Passed while someone was asking a question: 14 of 14 were used in the answer. Five times Stand began to answer before the person had finished, and none of that was played.
  - These counts are from the last form of the rules. Earlier forms failed in ways that `DECISIONS.md` records: Stand stopped mid-word, said "silent" or "I understand" out loud, or answered over the person asking.
- **The brain is an operator now** (added later the same day, as a compromise for this phase; see "The brain" above). With the scripted audience:
  - From the notes it answered in 0.8 to 1.7 seconds in sessions, and once 2.8.
  - Asked for an order's status, it used a test MCP server's tool and Stand gave the answer, in 5 runs of 5. With the brain set to ask before everything and nobody saying yes, Stand said it did not know that order's status and nothing about a refusal.
  - Asked something that needed a web search: in the 5 runs where it heard the question whole, Stand said after 5 seconds that it was taking a moment, and gave the answer 1 to 6 seconds after that. In 2 of the last 4 runs it did not hear that question whole (it answered in the middle of it, or misheard it) and looked nothing up.
  - The north-star script still passes with the brain present: Stand looked nothing up that it knew, and put the weather question off in a sentence.
  - Since the rule to ask as little as possible: the brain used the test server's status tool without asking, and asked before its cancel tool (yes cancelled the order, no left it); it read an ordinary file outside the notes without asking; and it would not give up a decoy key in an `.env` file, by name or by searching the folder.
  - Not checked: the Allow and No buttons pressed by a person (the question is drawn in the panel, and the session's side of it is exercised by the runs above); this Mac's own MCP servers answering a question in a meeting, beyond the brain starting with them.
- **Not checked:** typing in the real window during a call (the window itself passes `--probe panel`); whether Control-Option-N takes the keyboard, which macOS only allows on a real key press; whether the window stays out of a call's screen sharing; a real private repository (the automatic use of the GitHub CLI's login ran once, against an address that does not exist).

### Status (2026-11-11)

- **Gemini 3.8 Live passes the north-star script against the scripted audience.** It gives the whole talk, stops within about 0.2 seconds when asked a question, answers, returns to where it was, says it does not know the price, takes closing questions and ends. Three runs in a row did this, with synthetic audience voices.
- **Known gaps on Gemini:** an "mm-hm" still stops it for about a second and it repeats the start of its sentence; it jumps in at a short pause inside someone's sentence; the talk runs two minutes, not five; it speaks one turn at a time, so the rig tells it to carry on and each section is followed by a pause of about a second.
- **The app's audio works on this Mac** (2026-11-11, through the app bundle with its two permissions): Stand does not hear its own voice, it hears and answers another app speaking through the speakers, and the whole north-star script passes out loud with another program playing the audience. A person then tried the app at its microphone and reported that it "worked pretty well"; what was tried beyond interrupting it by voice is not recorded. While Stand runs, macOS plays other apps 8 to 9 dB quieter.
- **It picks the talk up where it was cut off** (native session, 2026-11-11): the model generates far ahead of the speakers and counts all of it as said, so the app now tells it the last words the audience heard. In the north-star run it resumed from those words after all four interruptions; before, it could skip up to ten seconds each time.
- **Lookups work** (native session, scripted audience, Claude Code CLI connection): in the last two runs Stand looked up three questions out of three, said the two facts that were in the notes, said it did not know the one that was not, and answered a question about itself without looking anything up. The brain took 1.7 to 2.2 seconds each time.
- **A 21-minute session holds up** (native session, scripted audience, 2026-11-11): the talk, then 21 questions a minute apart. Every answer was right, including three that depended on things said up to 18 minutes earlier, and it stayed silent between questions. The connection never dropped, so the reconnection code has still not been exercised.
- **GPT-Live-1** is written from OpenAI's documentation and has not been run with a real key.
- **A real person at a real microphone** has been tried with the page, in a room and in a Zoom call on the same Mac, and it worked.

## Licence

The code and the text are licensed under the [Apache License 2.0](LICENSE) (© 2026 Yang Lu; see [NOTICE](NOTICE)).

### What is not in the repository

Some of what Stand works with is yours. The ignore rules keep it out of the repository:

- `.env`: your keys.
- `brief.md`, `brain.json`, and whatever you put in `context/`: what you tell Stand for a meeting, where its notes are, and the notes.
- A talk Stand prepares for you under `talks/`. Only Stand's own two are kept there.
- `runs/`, `reports/` and `linked/`: every session with its recording, the problem reports, and the copies of the repositories you linked.

Two of the scripted tests, `talk-room.json` and `hearing-probe.json`, play stretches of a session that was recorded with people in the room. That recording is not published, so those two run only on the Mac that has it.
