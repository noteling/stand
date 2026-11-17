# Stand

Stand is an AI that attends meetings. It joins, it already knows the background, and it speaks up, out loud.

These pages are a small made-up wiki about Stand. They exist so that Stand has something to show while it talks: the test of the screen reads them.

## What Stand is

- A voice in the meeting, not a note-taker. It talks, and it stops when someone cuts in.
- It hears and speaks directly. No transcript sits between its ears and its mouth.
- It gives a talk, or it sits in a discussion and speaks when it has something to add.

## The four parts

| Part | What it does |
|---|---|
| The voice | Hears the room and speaks. One model does both. |
| The brain | Looks things up in the notes and the code while people wait. |
| The stage manager | Keeps the place in the talk, and decides the order of everything. |
| The screen | Shows the page for the section Stand is giving. |

The stage manager is ordinary code, not a model. It hands the talk to the voice a section at a time. The screen is a window of Stand's own, 1,280 points wide.

## How the screen keeps in step

The page changes only between sections, in the silence that is already there.

1. The page for the next section is put up.
2. The screen is looked at, to see what came up.
3. Only then is the voice told to give the section, and what the audience can see.

If a page does not come up, the voice is told so, and says so.

## What it cannot do yet

- It cannot join a call by itself. Someone starts it and shares its screen.
- It cannot point at a part of a page.
- It cannot tell who is speaking.
