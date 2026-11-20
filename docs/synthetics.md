# A Synthetics employee speaks through Stand

In this optional mode Synthetics supplies the employee's identity, memory, substantive answers and
commitments. Stand handles live audio and turn timing. There is no second Stand prompter or watch,
and Stand's notes, web settings and Claude setup do not become another source of answers.

The first increment joins a discussion (Attend, with no prepared Stand talk). Ordinary Stand modes
and the default settings are unchanged.

## Connect an employee

Install Synthetics into the Python environment you select. Provision its `stand` channel key and
explicitly enable meetings for that employee home with `floor.json` containing `{"enabled": true}`.
See Synthetics' [Floor contract](https://github.com/noteling/synthetic/blob/main/docs/floor.md).
The key is an adapter credential, kept in a private file; it is not a model-provider API key.

In Stand's own `brain.json`:

```json
{
  "connectionMode": "synthetics",
  "syntheticsPython": "/absolute/path/to/venv/bin/python3",
  "syntheticsHome": "/absolute/path/to/employee-home",
  "syntheticsKeyFile": "/absolute/private/path/stand.key"
}
```

Write the meeting's purpose in the usual brief and choose Attend. Stand starts
`python -m synthetics --home HOME floor attach --key-file KEY` and waits for the employee's ready
persona. A busy employee can yield its existing work first. Startup is bounded; a refused, disabled,
unavailable or ended employee fails closed rather than turning into ordinary Stand.

Stand still uses its own configured Gemini voice account. The employee's reasoning connection and
usage belong to Synthetics. Floor currently requires its persistent Claude meeting executor; the
configured gateway and Codex ordinary-work adapters do not yet provide that meeting capability.
This integration does not change a live employee's model, settings, opt-in or service.

## Who controls speech

The voice must ask the employee through `look_it_up` before every substantive response, including an
introduction or a simple answer. This call is explicitly blocking. The
[provider protocol](https://github.com/googleapis/googleapis/blob/master/google/ai/generativelanguage/v1beta/content.proto)
defines `BLOCKING` as waiting for the function response; the application also gates playback itself.

Only a matching current employee response permits one voice turn. Audio and speech text generated
without that permit are withheld. A new request, interruption, reconnection, panel correction,
hush, failure or completed response invalidates it. A completed tool-call generation while the
employee is still thinking does not invalidate the pending request. Timeouts do not produce a
spoken fallback. Losing the employee connection ends the voice session.

The voice may deliver the employee's response naturally, without adding claims or promises. The
playback gate checks provenance and lifecycle; it cannot prove semantic fidelity inside a permitted
turn. Live voice paraphrasing, ASR accuracy and real audio need their own evaluation. Durable promises
still pass Synthetics' `floor_accept` checks; voice output alone does not create employee work.

## What is retained

Heard words, generated speech, completed playback intervals and panel notes flow to the employee's
meeting journal through Floor. Room speech stays unidentified; a panel note is a separate source.
An interrupted interval carries its generated text and a cut time, rather than claiming all its
words were heard. Playback records use Stand's audio timeline, not independent measurement at a
listener's ears. The employee compacts the meeting afterwards using its normal wrap and summary path.
Synthetics journals have no automatic expiry. Stand also keeps its usual local run artifacts.

## Verification without a live employee

```sh
swift build --package-path mac
mac/.build/debug/Stand --probe synthetics --fixture-python /absolute/path/to/python3
python3 mac/scripts/check-synthetics.py --synthetics-source /path/to/synthetics
python3 mac/scripts/check-synthetics-compat.py --base origin/main
```

The native probe drives the real session controller with deterministic voice and employee connections.
It checks withheld independent audio, one correlated response, stale boundaries, failure, observations
and the ordinary Stand path. Protocol fixtures cover malformed/refused startup, old response IDs,
wrong revisions, cancellation and process failure. The Python driver runs the actual Floor process on
temporary homes with a fake headless model and verifies the final journal, wrap and released idle hold.
The compatibility check compares ordinary instruction bytes against an isolated Git baseline.
These checks use neither provider inference nor audio hardware. Supplying your own home to the
low-level `--floor-home` probe uses that home's configured executor and can consume model usage.

`VoiceConnection` and the optional session factories are maintained integration seams: a different
voice transport or employee connection can use the same controller. PCM rates and the current voice
wire adapter remain Stand-specific. Speaker identification, autonomous joining, prepared employee
talks and a panel for confirming commitment IDs are later work.
