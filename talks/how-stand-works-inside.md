# Talk: How Stand works inside

**Goal:** The three engineers leave knowing how the pieces fit together, how one interruption travels from the room to Stand's answer, and which parts are hard and why.

**Length:** about 10 minutes of talk. Then open questions.

**Audience:** Three engineers about to join the project. They write Swift and have used Stand once, but have never seen the code.

The sections below are points to make, in order. They are not a script.

## 1. Opening (about 30 seconds)

- Hello, I'm Stand, an AI, giving this talk for my human, who asked me to show you how I work inside.
- In ten minutes: how the pieces fit together, what happens between someone speaking and my answer, and where the hard parts are.
- Please interrupt me at any time, because handling interruptions is one of the things you'll be working on.

## 2. Two targets and one hub (about 45 seconds)

- The Mac app is a Swift package with two targets: StandCore holds the logic, and Stand holds the app, its panel and its command-line modes.
- At the centre is StandSession, ported from the JavaScript rig in poc and since extended well beyond it.
- StandSession knows nothing about microphones or speakers: sound comes in through hear, and its speech goes out through onSpeech.
- That is why a scripted audience can rehearse a whole talk against it with no audio hardware and no permissions.
- Everything runs on the session's own queue, and a timer ticks every tenth of a second to keep the meeting moving.
- Every session is saved under runs, with a recording, a transcript and a log of events.

## 3. How Stand hears the room and the call (about 45 seconds)

- Stand hears two things: the microphone, with macOS voice processing to cancel echo, and a Core Audio process tap for the call.
- It needs both, because Apple's echo canceller stops Stand hearing itself but removes the call's audio as well.
- The tap leaves out Stand's own output, and the two streams are mixed into one, at 16 kilohertz mono.
- The price of voice processing is that macOS plays other apps 8 to 9 decibels quieter while Stand runs, even at the lowest setting.
- For the first second after Stand starts speaking the room is ignored, because the echo canceller leaks until it settles.
- Stand hears the room as one stream, so it cannot tell voices apart by name.

## 4. Deciding when someone is speaking (about 45 seconds)

- Stand now decides for itself when someone starts and stops speaking, in SpeechMarker, and the voice service no longer decides.
- Left to the service, the first word after a pause was lost, so "Stand, do you know" arrived as "And do you know".
- The marker judges sound in 20-millisecond frames, and a frame counts as loud when it is well above the room's own steady noise.
- Four loud frames in ten open an utterance, which is handed over together with the 0.3 seconds of sound before it.
- Then 0.7 seconds of quiet ends the utterance, and that is when the model gets its turn to answer.
- The marker keeps no state except what it is fed, so a recorded run can be replayed through it offline.

## 5. The voice model (about 45 seconds)

- The voice is Gemini 3.8 Live, reached through GeminiLive, our own WebSocket client, whose wire format was captured from the JavaScript SDK.
- It goes from sound to sound: the live path never runs speech-to-text, then a text model, then text-to-speech.
- It generates far ahead of what is heard: a 25-second talk arrives in about 5 seconds.
- So the session keeps a virtual playhead, the moment when speech already sent will finish playing, and times everything by that.
- It speaks one turn and then waits, so something outside it has to keep a talk moving.
- The rig also has an adapter for GPT-Live, but it has never run with a real key.

## 6. One interruption, from start to finish (about 45 seconds)

- Take one question from our scripts: "Sorry to interrupt, but how many people attended the Tuesday pilot?"
- The marker opens an utterance, the service stops the model, and the session throws away whatever speech had not yet played.
- The model counts everything it sent as said, so if 1.5 seconds or more went unheard, it is told the last words that were heard.
- Those words come from the audio, not the transcript: the session finds a pause in the sound, then takes the nearest punctuation mark.
- Without this, Stand skipped 7 to 10 seconds of the talk at each interruption in the north-star run.
- Then the stage manager waits for 2.5 seconds of quiet before saying anything, so it doesn't speak into a pause inside the question.

## 7. Looking the answer up (about 45 seconds)

- Stand doesn't know the Tuesday figure, so it says "Let me check that" and calls its look_it_up tool.
- The session passes the question to the brain, which for now is the Claude Code command-line tool, kept open as one process for the whole meeting.
- The brain runs Sonnet at low effort, and notes of up to 400,000 characters are sent to it whole with each question.
- The answer, fourteen attendees, goes back as the tool's result, and Stand says it in its own words.
- An answer from the notes takes about a second, and then Stand goes back to its section.
- Before the meeting the brain also tells Stand what its notes cover, because Stand can't see them and would otherwise just say "I don't know".

## 8. When the answer is slow (about 45 seconds)

- An answer that needs the code takes 3 to 7 seconds on Stand's own repository.
- After 5 seconds, or 8 if the brain is busy reading files, Stand is told STILL LOOKING, says so, and carries on.
- The answer then arrives the way a note from its human does: at once if Stand is silent, otherwise in its next pause.
- Meanwhile "carry on" is held back for 9 seconds, so the next section isn't handed over while Stand is waiting.
- After 60 seconds the brain is stopped, and Stand says it could not find the answer.
- In the user's own words, the external command-line brain is a compromise for this phase and not the design, so don't build on it as settled.

## 9. The stage manager keeps the place (about 45 seconds)

- In a talk, the stage manager inside the session hands Stand one numbered section at a time, with that section's points.
- When the model reports its turn complete, the next section goes out 0.2 seconds after its speech has finished playing.
- Before this, Stand kept its own place over ten minutes, gave half a section twice and ran its last three sections into one.
- If it is stopped mid-section, it gets back only the points after the last one it plainly made, meaning half of that point's longer words were said.
- If Stand is sent back to a section and says nothing for 4 seconds, the next section is handed over.
- A signal that the talk is over is ignored while sections remain and nobody has spoken since the last one was handed over.

## 10. Three brains behind one voice (about 45 seconds)

- There are three separate brain processes: one answers lookups, one is the prompter, and one prepares talks like this one beforehand.
- The voice model keeps only the last three minutes word for word, because every turn is billed for everything it keeps.
- The prompter follows a transcript and keeps a sheet of four lines: so far, in play, worth saying, and owed.
- In a talk that sheet is Stand's memory: someone who gave their name early on was named, with their answer, nine minutes later.
- The prompter is the only place a transcript is used, and it decides what is put in front of Stand, never Stand's words.
- The preparer uses Opus at high effort, with fifteen minutes and no web, because what it writes is said in front of people.

## 11. Behaviour lives in plain text (about 40 seconds)

- Stand's behaviour lives in text files, under prompts, identity and talks, and the house rule is to change those before changing code.
- Every stage-manager message, every tool description and the rules for each role are prompt files that the session reads at the start.
- Project reads them, and Project.instructions puts together the right set for a talk or for a discussion.
- Wording matters: one rewrite of the lookup section made Stand look up the first question in only 3 runs of 7.
- Each on-the-spot choice gets one line in DECISIONS.md, the first place to look when Stand does something strange.
- A packaged app carries these files inside it, and a file at the same path in the user's Stand folder wins over the app's copy.

## 12. What the brain may touch (about 40 seconds)

- The rule for this phase is to ask the person as little as possible: useful but creepy, rather than useless and annoying.
- The brain reads files, searches the web and uses its MCP tools without asking, and asks first only before words like send, delete or pay.
- Two things are refused without asking: a file that looks like it holds secrets, and searching inside files outside the notes.
- The second rule exists because a plain search once read a hidden env file and gave away a decoy key.
- Inside its own folder the brain reads freely, so what goes into that folder is the only protection the code has.
- A rehearsal leaves out the user's own Claude Code setup, so scripted questions never reach their mail.

## 13. The hard part: the voice model's habits (about 45 seconds)

- Any speech-like sound stops Gemini, an "mm-hm" included, and none of its sensitivity settings changed that.
- Text sent while it speaks stops it exactly as a voice does, so a note waits for a pause found in Stand's own audio.
- Its transcript of its own speech can be off by up to 2.5 seconds, so never time a cut by the transcript.
- Text sent while it is silent always draws a spoken reply, even a word like "Silence", which is why the nothing_to_say tool exists.
- A message sent as a complete turn forces a spoken reply, while realtime text may simply be ignored.
- Many rules here look odd but hold things up, and each one has a measured run behind it.

## 14. How you test it, and what is untested (about 45 seconds)

- You test by rehearsal: the app's own binary, run with --rehearse, plays a scripted audience against the real session using the Mac's synthetic voices.
- Behaviour varies from run to run, so run a script several times before believing any one result.
- Rehearsals cost real money, because the service bills every turn for its whole context, and a ten-minute talk with questions costs about 85 cents.
- The twenty-dollar Gemini credit ran out mid-afternoon on 12 November, so check the spend probe before running a batch.
- Not yet tested: the present speech detector on a live real microphone, the Messages API brain, and any code base much bigger than Stand's own.
- Nobody has yet sat through a talk prepared like this one, by voice.

## 15. Close and questions

- "Stand is one session that listens, marks speech itself, hands a voice model one section at a time, and asks a brain when it doesn't know."
- Invite questions and answer them.
- When there are no more questions, thank the audience in one sentence and stop.

## If asked (not part of the talk)

- The room goes to the voice service as 16-bit mono at 16 kilohertz, and Stand's speech comes back at 24 kilohertz.
- While Stand itself is being heard, cutting in takes seven loud frames in ten, two of them at one and a half times the bar.
- A voice has to be louder than 500 out of 32768 to count at all, and STAND_VOICE_LEVEL changes that for one run.
- While the room is quiet, the session sends a tenth of a second of silence every 20 seconds, or the service closes the session after about two minutes.
- A session waits up to 12 seconds for the brain to start, and if it isn't ready, Stand has no lookup tool for that meeting.
- Each minute of speech the voice model keeps costs about 1,500 tokens on every turn, and the service cuts back 30 to 45 seconds late.
- The brain's question to its human shows in the panel with Allow and No for 20 seconds, and no answer counts as no.
- A note is a Markdown or text file of at most 1 megabyte, and at most 2,000 notes are read.
- A GitHub repository is copied through GitHub's API, not git, and an archive over 100 megabytes is refused.
- Hush is Control-Option-S, and Control-Option-N puts the keyboard in the note field.
- The JavaScript rig was frozen when the session was ported, so lookups exist only in the Swift code.
- There is no Xcode on the development Mac, so "swift build --package-path mac" is the quick compile check.
- Don't change a file in the repository while the system-talk rehearsal runs: the repository is the brain's notes, and a changed file restarts the brain.
- The package script builds a disk image for Apple silicon and Intel, and the app is notarized only when the user says yes.
- Not in the notes or the code: who owns which part of the code, any release date, a version history (the project folder isn't a git repository yet), and timings on a code base much larger than Stand's own.
