# Stand

Stand is an AI that attends meetings. It joins, it already knows the background, and it speaks up, out loud, as a character with a goal.

## Where the name comes from

In JoJo's Bizarre Adventure, a Stand is a being that appears beside its user and acts with abilities of its own. That is the picture here. Stand is an independent character, and for now it is tied to a human who is in the same meeting. It stands next to that person; it does not replace them.

## What Stand is

- **An attendant, in the room.** It takes part in the meeting while it is happening.
- **Briefed.** It arrives knowing the background, the way a prepared colleague would.
- **A voice.** Everything it does in the meeting is spoken.
- **A character with a goal.** Who it is and what it is there to do are both set before the meeting. The character is how it behaves; the goal is what it is trying to get done.

## What Stand is not

- It is not a note-taker, a transcript tool or a meeting summarizer. The value is in what it does during the meeting.
- It is not a stand-in for a person who skipped the meeting. Not yet.
- It is not an assistant waiting to be asked. It can hold the floor, and it can speak up without being prompted.

## What we believe

1. **How it speaks matters most.** When people talk, the tone and the delivery carry as much as the words. So Stand listens to voices and answers with a voice directly. A transcript never sits between its ears and its mouth.
2. **Thinking can live behind the voice.** A separate thinking system may help with knowledge and hard questions. It hands Stand the point to make, and Stand decides how to say it.
3. **It should not depend on one meeting product.** Stand lives on its human's computer and takes part the way a person at that computer would: it hears the call, speaks into it, and presses the same buttons.
4. **Build it, then look at it.** We make a rough version, see what it actually does, and improve from there.

## The first test

Stand has to be able to introduce itself. It joins a meeting whose whole purpose is to present Stand, gives the talk, takes questions that interrupt it, answers them, returns to the talk without losing the thread, and finishes with open questions. If it cannot do that, it has failed.

## After that

The second scenario is a discussion among people, where Stand has a view of its own, formed from its background, and picks its moment to speak. A first form of it exists. Stand can sit in a meeting without giving a talk: it stays quiet while people talk to each other, answers when it is spoken to, and speaks up when the discussion reaches what it is there for. So far it has done this only with recorded voices, not with people.

## How it is put together

- **Ears and mouth:** a voice model that hears speech and produces speech.
- **Brain:** a thinking system behind the voice, for knowledge and harder reasoning. A first form is built: it looks up facts in notes its human has given it, and in the code of a system when its human has given it that too. These can be folders on the computer or repositories on GitHub. It can look further, on the web or with tools on the computer. Before a meeting it can write the talk Stand will give, from those notes and that code. During a meeting it follows along beside the voice, the way a prompter does for a speaker. In a discussion it keeps the thread of what has been said, has the facts ready that bear on it, and now and then hands Stand a point worth making. In a talk it keeps track of where the talk stands and of what Stand has promised, because the voice itself holds only the last few minutes word for word. For now that brain is a separate program on the computer, which is a stopgap and not the final design. Harder reasoning is planned, not built.
- **Hands and eyes:** the ability to press buttons in the meeting app, such as unmute, and to see what is on a shared screen. Planned, not built.

## Where things stand today

This is an early proof of concept.

- It runs on a laptop: a microphone in, a voice out.
- It hears the room as one stream of sound. It cannot yet tell who is speaking by name.
- It has no connection of its own to Zoom, Meet or Teams. It can still take part in a call the simple way: beside its human, hearing the call through that computer's speakers and being heard through its microphone. This has worked in a Zoom call.
- It cannot press buttons or share a screen yet.
- Two voice models are being compared, and the choice is not final.
- It knows what is written about it here. It can also look a fact up, which takes a few seconds, sometimes longer: in notes or code its human has given it, on the web, or in other systems its human has connected.
- Its human can brief it before a meeting, and can pass it a private note while the meeting is going on. It acts on both without mentioning them.
- Asked something only its human can say, it says that it will check with them, puts the question to them privately, and comes back with the answer.

## Not decided yet

- What the finished product looks like, beyond it being an app on your computer.
- Pricing, release dates, and who it is for first.
- How much it may decide or commit to on its human's behalf in a real meeting. For now we assume it can.
