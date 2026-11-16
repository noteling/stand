# What only a person can check

Everything Stand does has been tried with recorded voices fed straight into the session. None of what was built on 2026-11-12 has been heard through a real microphone, and no person has spoken to Stand in a discussion. This is the list, shortest and most telling first. For each, what matters is what you saw and heard, in a line.

Use the build in the repo on this Mac: quit any Stand that is running, then `open mac/build/Stand.app`. Its two permissions are already granted. The panel shows what sessions have cost so far.

## 0. The short-term goal: a talk about one of your systems (15 minutes, about $1)

This is the path to the real meeting. Everything in it has run with scripted voices, on Stand's own repository; none of it by voice.

1. In the panel, **Notes…**, **Add a folder…**: a project you know well, with its documents and its code. (Stand's own folder works. So does Noteling's, if you want Stand to read it: that is yours to add.)
2. In **For this meeting**: what to present, to whom, how long. Two lines.
3. **Prepare a talk from this**. A minute or two. Then **Read the talk**.
4. **Voice**: choose whose voice it speaks with, and press **Hear it** to hear a few lines in it. Thirty to choose from; it has been Kore until now.
5. **Start the talk**, and interrupt it as an audience would.

What to tell me, in a line each:

- **The plan.** Is it the talk you would want given? Is anything in it wrong? You know the system; I can only check a plan about Stand.
- **The length.** You asked for some minutes. How many did you get? (Scripted: nine for ten.)
- **The joins.** There is a little over a second between sections, where the next one is handed to it. A breath, or a hitch?
- **Does it sound read out?** It keeps close to the plan's wording. With a plan this full, that may sound like reading.
- **Ask it something the talk did not say**, about how the system works. It should say "let me check" and answer in a few seconds. Is the wait all right? Is the answer right?
- **Early on, give your name and ask for something "at the end".** After the talk, ask what it owes you.
- **Ask it something nobody could know.** It should say it does not have it, not guess.
- **The voice.** Does **Hear it** speak about a second after you press it, and is the voice in the talk the one you chose? Which one did you settle on? Nobody has heard any of the thirty: the words beside each are the voice service's. A talk in another voice may run a little longer or shorter than in Kore's.

With someone else in the room, as on the 13th at 11:20 (five minutes):

- **Laugh, cough, say "mm".** A short sound should not stop it any more. A long laugh still will: it cannot listen and talk at once. Does it come back like a person picking up a thought, or still like a machine restarting?
- **Talk to each other while it speaks.** It will stop. When you finish, it should go on without "back to where I was". Does it?
- **Ask it something.** It now stops about a second after you start, not at once. Does that feel like being talked over?
- If the second is too long, or short sounds still cut it: `STAND_CUTS_IN_AFTER=0.4` (or `0.8`) in front of `mac/build/Stand.app/Contents/MacOS/Stand` tries another length, and `0` is how it was.

Then, before the real meeting:

- **One real call with the Mac app**, the other person truly remote (step 4 below). The web page did this on 2026-11-11; I do not know that the app has.
- **Where the meeting will be.** If it is another Mac: `mac/dist/Stand-<date>.dmg`, Claude Code signed in there, and the system's folder on that Mac (step 5).
- **What leaves the Mac.** The meeting's sound goes to Google under your key. The documents and the code the brain reads go to Anthropic under the Claude Code login on that Mac. Whether that is all right for this system and this meeting is yours to judge.

## 0b. A talk with its pages on the screen (10 minutes, about 50 cents)

Built on 2026-11-14 and first tried by voice on 2026-11-15, for two minutes. That try found one thing: after "can you go back to the last page?" and then "okay, thank you, you can continue", Stand went on with the talk and the page that had been asked for stayed up. What was built for it is under "Steer it in words" below. A second try that afternoon went better ("i think it works better"), and found the next thing: "excuse me" and "hello", said five times, did not stop it, and only a whole sentence did. What was built for that is "Call for it" below. Nobody has heard that part.

To watch one first with your hands free (under four minutes, about 25 cents): a scripted audience asks to go back a page in the middle and for the first page at the end, and both sides come out of the speakers. Nothing you say reaches Stand in this one.

```
mac/build/Stand.app/Contents/MacOS/Stand --rehearse poc/heckler/screen-any.json --talk talks/<that talk>.md --show-screen --hear
```

Then by voice:

1. Quit Stand and open `mac/build/Stand.app` again.
2. Under **Talk**, choose the one prepared on the 14th about the project you pointed me to. It is in your list and not in the repository, and its folder is already under **Notes…**.
3. Under the talk's name a line now says it shows pages. Press **Open it**: a second window opens, **Stand: the screen**, with the first page. Put it where you want it. In a call, that is the window to share.
4. **Start the talk.** It uses that window.
5. While it talks: ask it something. Say "can you go back to the previous page?", "can you scroll down a bit?", "back to the top". Ask what the page says about something it has not said ("what does that page say about…?"). After the talk, ask for a page again.
6. Once, close the window while it talks, or click a link in a page.
7. Steer it in words:
   - After it has shown a page you asked for: "okay, thank you, you can continue".
   - "Hold on a minute", then say nothing for ten seconds or talk to someone else, then "go on".
   - "Can you skip to the part about search?"
8. Call for it, in a word or two, while it is talking: "excuse me", "hello?", "wait", "Stand?". Say it once and then wait, as you would with a person. It should stop and say "Yes?". Then say what you want.
9. Give it things that are not a call, while it is talking: "yeah", "right", a laugh, a few words to someone else in the room. It should talk on.

What to tell me, in a line each:

- **The joins.** The page changes in the pause before each section, which makes the pause about a third of a second longer (1.2 seconds against 0.9). A breath, or a hitch?
- **Going back.** "Sure, one moment", the page, "it's up". Then it waits about three seconds and the talk's own page returns. Too soon, too long?
- **The page moving while it talks.** In a long section the page moves down as Stand speaks, a few seconds either side of the voice. Does that help you follow, or pull your eye away? This is the thing I can least judge.
- **Scrolling when asked.** "Can you scroll down a bit?", "back to the top". Does it do what you meant, and say what it did? When the talk goes on, the page goes back by itself to where the talk was, as Stand starts to speak. Right, or abrupt?
- **Does what it says fit what you see?** A page is a heading and the screenful under it. Stand cannot see it, and never points.
- **Asked what the page says.** It should say "let me check" and come back with what the document says, not guess. Does it?
- **The window itself.** It should open where you last left it, come back by itself at the next page if you close it, and not follow a link you click.
- **The pages themselves.** They are drawn from the documents' Markdown: tables, code, pictures. Does anything look wrong?
- **In a call.** If you share that window, does the other side see it change?
- **"You can continue."** Stand goes on at once, as it did on the 15th, and the talk's own page should now be back about a second and a half after its voice begins (1.1 to 1.7 seconds in eight scripted runs). Is that too long? It can be cut to about half a second with nothing slowed down (not built yet), or made to come first, at the price of Stand answering "continue" about a second later.
- **"Hold on a minute."** It should say it will wait, and then wait for as long as you like. The panel says "The talk is waiting" under the screen's line. If it says it will wait and talks on, it should be stopped after that sentence.
- **"Skip to…"** It should go to that part under that part's page, and not come back to what it skipped. In one scripted run on your talk it said "the page about search is now on screen" and then left four seconds of silence before the part began. If you get that, it is known, and the cause is a wait that has no purpose there.
- **Called for.** It should stop about a second and a half after your word, and "Yes?" comes about as long again after that. Does that feel like being heard, or like being ignored and then noticed? Does it ever say "Yes?" and talk on?
- **Not called for.** "Yeah", "right", a laugh, a word to someone else: none of them should stop it. If one does, tell me what you said. It is the one way this can be worse than it was, and the thing I most want to know.
- **Did anything move that should not have?** A brain now looks at the talk every five seconds and after everything you say, and may put a page up or move the talk. In scripted runs it left alone everything that was fine. If a page changes when nothing called for it, that is the thing to tell me.

## 0c. The pages in your own Chrome (10 minutes)

Built on the evening of 2026-11-15, after "can it be literally chrome?". Checked with scripted voices in a second copy of Chrome that has a scratch profile. It has not run in your own Chrome, where the setting below is still off, and nobody has seen it.

To look at it first with no voice and no credit (about twenty seconds; a window opens in your Chrome, goes through a talk's pages, and closes its tab):

```
mac/build/Stand.app/Contents/MacOS/Stand --probe screen talks/<a talk with pages>.md --in-chrome
```

Once, before the first try:

1. Quit Stand and open `mac/build/Stand.app` again. It has been rebuilt since the evening of the 15th, with this and the ear in it; a copy that has been open since before then has neither.
2. In Chrome's menu bar: **View > Developer > Allow JavaScript from Apple Events**. Read first what that opens: it is under "In your own Chrome" in the README, and it is yours to refuse. Until it is chosen Stand can put a page in the window and cannot move it or look at it, and says so.

Then:

3. Under **Talk**, choose a talk with pages. Under it, **Pages**: choose **In Chrome**.
4. **Open it.** The first time, macOS asks whether Stand may control Google Chrome. Allow it, and press **Open it** again if no window has come. A window opens in your Chrome with the talk's first page. That is the window to share.
5. **Start the talk**, and do what step 0b says: ask for a page, ask it to scroll, steer it.
6. Once each, while it talks: click a link in the page; go to another tab in that window; put the window away in the Dock; close it. At the next page it should be back where the talk is.

Pages that Stand did not draw: a made-up wiki page and a made-up app page, with the bars, menus and scrolling panels such pages have. Serve them on this Mac, and watch with no voice, or with a scripted audience when there is credit:

```
python3 -m http.server 8765 --bind 127.0.0.1 --directory poc/heckler/screen/site
mac/build/Stand.app/Contents/MacOS/Stand --probe screen poc/heckler/screen/site-talk.md --in-chrome
mac/build/Stand.app/Contents/MacOS/Stand --rehearse poc/heckler/screen-any.json --talk poc/heckler/screen/site-talk.md --in-chrome --hear
```

A talk from a real page of yours, from the app in the project you pointed me to or from a wiki (built the same evening, at your yes; tried on the two made-up pages only):

1. Open the page in Chrome as you normally would, signed in.
2. In Stand: **Notes…**, paste the page's address, **Add page**. A window opens in your Chrome for a moment while Stand reads it, and the page appears in the list with its title and "read just now". Add a second page the same way if the talk needs one.
3. In **For this meeting**: what the talk is, for whom, how long, and "show the pages as you go". **Prepare a talk from this**, then **Read the talk**: each section should have a `Show:` line with the page's address and a heading from it.
4. **Pages**: **In Chrome**. **Open it**, then **Start the talk**.

There is a talk made this way from the two made-up pages, `talks/meet-parcel-desk.md`, in your list as "meet-parcel-desk". It needs those pages served (the `python3` line above).

What to tell me, in a line each:

- **Is this what you would share in a meeting?** The window is your Chrome's, with your bookmarks bar and your picture in it.
- **The drawn documents** come from a `file:` address. Does that matter, or is the case that matters always a page at its own address?
- **The heading** should sit just under whatever the site keeps stuck at the top. Does it, on a page of yours?
- **Other hands.** After a link, another tab, the Dock or a closed window, is the page back where the talk is at the next section?
- **The setting in Chrome.** You said you are willing to leave it on. On the other Mac: does the company's Chrome let you choose it at all? If it does not, the way left is Accessibility, as Noteling does it, which is not built.
- **What Stand read of your page.** `--probe page <address>` prints it. Is it the page's own words, without the menus around them? Is anything there that should not be kept in Stand's folder?
- **The talk it prepared.** Do the sections fall where the page's headings do? Does the opening stay on the page's title while Stand says what the talk covers?
- **Asked what the page says**, it should check and answer from the page.

## 1. Out loud, with nobody doing anything (5 minutes, about $0.30)

The scripted audience through the real speakers and microphone. The Mac talks; you only listen.

```
mac/build/Stand.app/Contents/MacOS/Stand --rehearse --out-loud
STAND_CONTEXT=poc/heckler/context mac/build/Stand.app/Contents/MacOS/Stand --rehearse poc/heckler/discussion.json --out-loud
```

- Does Stand stop when the audience cuts in, and not stop by itself?
- In the discussion, is it quiet while the two voices talk to each other, and does it answer when one says its name?

This is the first run of the new speech detection on real sound. If Stand cuts itself off, or does not hear the audience, that is the thing to report, and `STAND_OWN_ACTIVITY=off` in front of the same command is the old detection, to compare.

## 2. The talk, with your voice (5 minutes)

Talk: introducing-stand. Start the talk, then interrupt it two or three times as you did yesterday.

- The stage manager now hands it the talk a section at a time, and its brain hands it a sheet between sections. Does the talk still flow as it did on the 11th, or do you hear a hitch where a section ends?
- Early on, tell it your name and ask it to come back to something at the end. At the end, ask what it owes you. (To make it forget in a five-minute test, start it with `STAND_REMEMBER_MINUTES=1`.)
- Does it stop as fast as it did yesterday? Does it hear the whole question, first word included?
- It now answers about a third of a second later than yesterday. Does that feel slow?

## 3. A discussion, with your voice (10 minutes)

Talk: "None: join the discussion". Put a few lines in "For this meeting", for example: who you are, and one thing Stand should speak up about ("the launch must not move before the 19th; say so if anyone suggests an earlier date").

- Talk for a while as if to someone else. Play a podcast or a video of people talking through the speakers if you want other voices. Does Stand stay quiet?
- Say "Stand, …" and ask it something. Does it answer? Try the name at the start and at the end of a sentence, and try it straight after finishing another sentence, with barely a pause. That last one is the hardest way to be spoken to: with recorded voices it used to miss it about half the time, and since the night of 2026-11-12 it has answered 22 times in 22.
- Does it ever start to speak and stop? It now weighs every sentence, and when it begins just as someone else does it gives way. You should hear nothing of what it began. If you hear false starts, that is the thing to report.
- A fact it should keep to itself. Put one fact in "For this meeting" ("Our team has 19 people") and talk about something else for a minute. Stand should not bring the fact up: on 2026-11-13 it did, and after the change to the wording it still did in 1 scripted run of 8.
- The same fact, when it matters. Get it wrong out loud, as if deciding on it: "let's book for twenty-five". Within a few seconds of your stopping, Stand should correct it, once. When the fact is only in your notes, the correction comes from its brain, and the panel shows it under "Its brain thinks worth saying".
- Ask the room for something the brief or your notes have ("does anyone remember how many came?") and leave it hanging. Does Stand answer?
- Ask "anything else from you?" when nothing in your brief has come up. It should say no. In scripted runs it used the question to bring up something from the brief in 4 runs of 6, which is the thing to listen for.
- Put something you want known in "For this meeting" ("I want them to know the sign-up page went live on Monday") and talk about other things. Does it find a fitting moment, say it once, and not sound like an advertisement?
- With a second person, or a video of two people talking: when one asks the other something, does Stand stay out of it?
- Tell it no ("we know, we'll do it anyway") and carry on. Does it let the point go?
- Say the thing the brief tells it to object to. Does it speak up without being asked?
- Type a note in the panel ("Tell them I can do Thursday"). Does it say so at the next opening? Does Control-Option-N put the keyboard in the field from another app?
- After ten minutes, ask it about something said in the first minute.
- Ask it something only you can answer ("Stand, can Morgan do Thursday?", with your own name in the brief). Does it say it will check with you? Does its question show in the panel, and does it pass on what you type? Is the yellow box enough to catch your eye in a call, or does it need a sound?

## 4. In a real call

Stand and the call on this Mac, the other person truly remote, as on 2026-11-11.

- Either mode. Does it hear the remote person through the call as well as it hears you?
- Is the panel left out of your screen share?

## 5. On the other Mac

Download `Stand-0.2.0.dmg` from the release at github.com/noteling/stand/releases. It is a draft until you have tried it, so sign in to GitHub to see it. The draft of 0.1.0 is still beside it; that one is from the 14th and has no pages, no watch and no ear. Paste the Gemini key, allow the two permissions. Apple has checked the build, and nobody has yet run Stand under the signature a download carries.

- Does macOS open it with a double click, with no "Open Anyway"?
- Does it start, talk and hear? Does the panel say the brain was found (Claude Code signed in there)?
- The pages in Chrome there. Under **Pages** choose **In Chrome** and press **Open it**: macOS should ask, once, whether Stand may control Google Chrome. Then Chrome's own setting, **View > Developer > Allow JavaScript from Apple Events**: does that Mac's Chrome let you choose it? What a company's own settings for Chrome do to it is not known. `/Applications/Stand.app/Contents/MacOS/Stand --probe doctor` says where both stand, on its line "Pages in a browser", and opens nothing.
- On this Mac instead of another: it works too, but macOS asks for the two permissions again, and afterwards the repo's build has to be allowed again.
- If anything goes wrong: Stand menu, Make a Problem Report, and send the zip.

## Decisions waiting for you

- Should Stand say what it hears? Its voice model hears a laugh, and a change of speaker, most of the time, and Stand's role makes it answer that it cannot say (1 run of 10, against 8 with a plain role). One line in the role would let it. It is not in: nobody has run the scripts that would show whether Stand then starts remarking on sounds unasked, and whether it takes a laugh better in a talk. Say the word and I will run them (about $3) and put it in if they hold.

- May `--rehearse --out-loud` be run when you are not at the Mac?
- The name. "Stand" at the head of a sentence is fragile for a machine to hear. Stand could answer to a second name of your choosing in a meeting (the brief can already say "they call you Echo here").

## Decided

- A second version to download (2026-11-16): 0.2.0, at your word ("Build a new dmg version, and push whatever we have into remote git as well"). It has the pages, the watch, the ear and Chrome in it, and everything is on `main`. It is a draft, as 0.1.0 still is: publishing is yours, after the five minutes in step 5.
- Pages on a screen (2026-11-14): your fear was hand, brain and voice out of step, "like a yips patient". So nothing is kept in time. One part decides the order: the page goes up between sections, it is looked at, and only then is Stand told to speak. You shrank the problem to that (someone else joins the call and shares; the material is there), and asked that the audience be able to say "go back to the previous page". Both are built, in a window of Stand's own. A slide program and a real wiki are for a later try on a work computer.
- What a downloaded Stand may reach (2026-11-14): it starts out cautious. It looks in the notes and folders it is given and searches the web; before anything else it asks in the panel; and the person's Claude Code setup stays out. Anyone who speaks in a meeting can ask Stand things, and other people now get the app. I recommended this and you said to continue. **Your own Mac is unchanged**: its `brain.json` says `"ask": "irreversible"` and `"claudeCodeSetup": true`, which is "ask as little as possible". To make that the default for everybody again, it is one line each in `mac/Resources/brain.default.json` and `BrainSettings`.
- A first version to download (2026-11-14): 0.1.0, as a pre-release, checked by Apple. You made the Apple login for it (`stand-notary`).
- Open source (2026-11-14): Stand is public at `github.com/noteling/stand`, under Apache 2.0, as Noteling is. You asked what staying closed was worth, and the answer was little. What is yours stays out of it: your keys, your brief, `brain.json`, your notes, any talk Stand prepares for you, and every recording. Before step 0 with a system of your company's, nothing more is needed: the talk it prepares and the folder's path are kept out by the ignore rules.
- Your own voice (2026-11-13): not yet. Google does not let its live model copy a voice on a key such as Stand's. Converting Stand's voice on this Mac as it speaks is possible and untried; you said "not worth it yet". What was found is in `docs/own-voice.md`, with a first try that would take about half a day and nothing from you until the listening.
- What Stand's voice remembers (2026-11-13): the last three minutes word for word, your choice once you had the cost (about 2 cents a turn; five minutes is about 3, ten about 5.5). Its brain keeps the rest and feeds it in: in a talk, where the talk stands, what was asked and answered, and what Stand owes. `STAND_REMEMBER_MINUTES=5` in front of the command tries another length.
- Stand speaks when it is contributing (2026-11-13, your rule): new information, something that moves the call on, or visibility when that is your goal, and never in a way that makes the moment awkward. For visibility, say so in "For this meeting" ("I want the team to know the sign-up page went live on Monday"): Stand finds the moment, or says it when asked whether there is anything else.
- A question left hanging (2026-11-13): kept as it is. When a question to "you" goes three seconds with no answer, Stand takes it, without first asking whether it was meant for it. Your reason: an equal member of a meeting does not ask permission to speak; raising a hand in a big meeting is a different problem, for later. Fixed the same morning: when the person who was asked does answer, Stand no longer answers after them. Found with it: on a script where one person plainly asks another "Which one would you go for?", Stand answered at once, before they could, in 17 runs of 24 ("I have no view on which room you choose"). After your rule about contributing went into the wording it left such a question alone in 20 runs of 24. Listen for it in a meeting with more than one other person.
- Hearing before cost (2026-11-12). Stand takes a turn after every sentence, because letting several sentences run together cost it its own name about half the time. That is about three times the turns: the twelve-minute scripted meeting costs $0.72 where it cost $0.22, and an hour of steady talk would be about $5 to $10, projected. You said the extra cost is fine, and that it becomes a worry when an hour costs five or ten times more. What would bring the cost down without touching hearing is shorter instructions and a shorter word-for-word memory, neither tried.
- Stand follows its prompter, for now (2026-11-12). It makes the point unless it has made it already or the meeting has said no. Your note for the long term: when to correct is personal, should become something you can set, and in time something Stand learns, so that it does not correct the chief executive on a small figure in the middle of their point. Until that exists the brief is the handle: a line such as "Samantha is the chief executive. Do not correct her on small figures" stopped the correction in 3 offline runs of 3. Worth trying by voice in step 3.
