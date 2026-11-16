# Talk: a made-up system, shown from pages Stand did not draw

**Goal:** a short talk whose pages are addresses, built the way a company wiki and a web app build theirs: a bar fixed over the top, a menu with headings of its own, words that arrive after the page has loaded, a panel that scrolls inside a window that does not, and a section too near the end of its page to come to the top. Section 4 asks for "Storage" on a page that has just been loaded again, when its own words have not arrived and the only heading of that name is the menu's. It exists to test the screen on such pages. The pages are in `poc/heckler/screen/site/` and have to be served on this Mac first:

    python3 -m http.server 8765 --bind 127.0.0.1 --directory poc/heckler/screen/site

**Length:** about two minutes of talk. Then open questions.

**Audience:** people who have not seen Parcel Desk, which does not exist.

The sections below are points to make, in order. They are not a script.

## 1. Opening (about 10 seconds)

Show: http://127.0.0.1:8765/wiki.html

- Say who you are: Stand, an AI, and that you will walk through Parcel Desk, the system a mailroom uses to keep track of parcels, from its own pages.

## 2. How a parcel moves (about 50 seconds)

Show: http://127.0.0.1:8765/wiki.html # How a parcel moves

- A parcel goes through six steps, and each is recorded with the time and the person who did it.
- On arrival the receptionist scans the courier's barcode, and a record is created with the courier's name and the time of arrival.
- A label with a short number is printed, and from then on the short number is the only thing anyone needs to quote.
- The name written on the parcel is matched against the staff directory, and the three closest names are suggested, because handwriting on parcels is hard to read.
- The owner gets a message in the chat tool with the short number and a photograph, one reminder after a day, and after five days their manager is told.
- The parcel goes on a numbered shelf that is scanned, and large parcels go to the cage in the basement.
- To collect it the owner shows the short number and signs on the tablet, and the record is closed and kept for a year.

## 3. The one thing that breaks (about 40 seconds)

Show: http://127.0.0.1:8765/app.html # Restarting the printer

- The label printer stops about once a month, and its runbook says what to do in order.
- Switch the printer off at the back and wait ten seconds, because the print head has to cool down before it will reset itself.
- Open the lid, take the roll out and look at the rubber roller: a label stuck to the roller is the cause nine times in ten.
- Put the roll back with the labels facing up and feed the first label under the green guides until its edge shows at the front.
- Switch on and hold the feed button for three seconds until the light turns green, which makes the printer measure the length of a label again.
- Print a test label from the settings page of Parcel Desk, and if the number is cut off at one side, run the alignment from the same page.

## 4. Where it is kept (about 20 seconds)

Show: http://127.0.0.1:8765/wiki.html # Storage

- Everything is in one PostgreSQL database with three tables: parcels, the steps each went through, and shelves.
- Photographs are deleted after ninety days, and the records are kept for a year after collection.
- The database is copied to the backup server every night, and restoring from it took eleven minutes when it was tried.

## 5. Who to ask (about 10 seconds)

Show: http://127.0.0.1:8765/wiki.html # Who to ask

- The mailroom team owns Parcel Desk: ask in the mailroom channel, or at the desk on the ground floor.

## 6. Close and questions

- One sentence that sums it up: a parcel gets a short number at the door, and that number is all anyone needs until it is signed for.
- Invite questions and answer them.
- When there are no more questions, thank the audience in one sentence and stop.

## If asked (not part of the talk)

- About 180 parcels arrive on an ordinary day, and three times that in December.
- A parcel with no readable name goes on the shelf marked "unknown".
- If Parcel Desk itself is down, the paper book is in the top drawer.
- Not on the pages: what Parcel Desk cost to build.
