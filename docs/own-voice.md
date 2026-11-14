# A voice of your own

Looked into on 2026-11-13. **Not built.** The user's word on it the same day: "not worth it yet". The first real meeting uses one of the thirty stock voices (README, "Whose voice").

This is what was found, so that nobody has to find it again.

## The questions

The user asked three things in a row:

1. Is Stand's voice configurable, "like whose voice to use"?
2. Google will not let it use your own voice: "is that some risk for them? Or it's rather have some tech difficulties"?
3. "IF we can easily wrap a layer which has almost no latency, but convert the voice to 'what we want', is that tech possible, but that probably need us to not use any llm or remote model for conversion for the wrapper layer".

The first is built: the Voice menu. The other two are below.

## What the voice service allows

Tried against the service with Stand's key, and read in Google's documentation, on 2026-11-13.

- The live model (`gemini-3.8-live`) takes thirty voices by name and nothing else. Given any other name it does not refuse: it speaks with Zephyr's voice.
- Google can copy a person's voice ("voice replication") and can make a voice from a description ("voice design"). Both are for its text-to-speech models (`gemini-3.8-flash-tts`, `gemini-3.8-flash-lite-tts`).
- A copied voice takes two recordings from the same person: 10 to 30 seconds of clean, natural speech, and a consent statement read aloud. Google checks the consent recording by matching what is said in it against the statement. 24 kHz mono 16-bit WAV is what they recommend.
- For a live session, the setup message has a place for this (`replicatedVoiceConfig` in `voiceConfig`, with `voiceSampleAudio`, `consentAudio` and, afterwards, a `voiceConsentSignature` that the service hands back so the consent need not be sent again). Google's forum has it that the live model accepts this and ignores it when reached with an API key, as Stand reaches it. Google's cloud platform documents it for live sessions, for customers it selects.
- Not tried here. Trying it takes a real person's recording and their own spoken consent, and neither was made up.

If Google opens this for the live model on an ordinary key, Stand needs little: the two recordings, made in the panel by the person whose voice it is, and those fields in `GeminiLive.connect`.

## Why it is held back

Risk, not difficulty, as far as the evidence goes. Google's own reason was not found stated; this is an inference from three things.

- Google has it working: on the text-to-speech models, and on the live model for customers it selects, behind a consent check.
- OpenAI says the reason outright for its own models. The GPT-4o system card rates voice cloning and impersonation as a high-severity risk (fraud, deepfakes of people who did not agree) and holds the model's speech to preset voices. Its voice-cloning tool, meant for its API in March 2024, was still unreleased a year later.
- A model that holds a live conversation in anyone's voice is the tool a scam call needs. A text-to-speech model that reads a script in that voice is less so.

Other makers of live voice models do offer a custom voice: Ultravox's documentation describes one made from an uploaded sample. Not looked into: whether such a model speaks directly or through a text-to-speech stage. That matters, because Stand's first rule is that no text sits between hearing and speaking.

## The user's idea: convert the voice after the model

It exists, and it is called real-time voice conversion: sound goes in, the same speech comes out in another voice. It is what "AI voice changers" do.

The user's instinct about it is right on both counts.

- **Local.** A remote model adds a trip over the network for every piece of sound, and gives the meeting's audio to one more company.
- **Not a language model.** It is still a neural network, but a small one that runs on the Mac's processor.

What was found, in an hour of searching. **These are the authors' figures. Nothing here has run on this Mac.**

| What | Delay | The target voice | Notes |
|---|---|---|---|
| LLVC (Koe AI, 2023), open source | under 20 ms | one voice for each trained model | Runs 2.8 times faster than real time on a consumer processor. Works at 16 kHz; Stand speaks at 24 kHz. |
| MeanVC 2 (June 2026), 18M parameters | about 110 ms to the first sound, in 40 ms pieces | taken from a short clip, no training | Uses under two thirds of one processor core. Its code was still described as forthcoming; check before counting on it. |
| RVC, through the w-okada voice changer | not found measured | one voice for each trained model | The best known. Lists support for Macs with Apple silicon. |
| Seed-VC | not found measured | taken from a short clip | Described as able to run in real time, with a Mac setup. From a blog, unverified. |
| StreamVC (Google research) | not found measured | taken from a short clip | No Mac build found. |
| No model: shifting pitch and formants | next to none | none | Makes a different voice, never a particular person's. |

Product pages for commercial voice changers claim under 30 ms on Apple silicon. Those are advertisements.

## Why it would fit Stand

- **No transcript.** A converter works on the sound, so the timing and the intonation the voice model chose come through. That is the difference from text-to-speech, and it keeps the first rule.
- **The delay is paid once for each reply.** Stand's speech arrives from Google at least as fast as it is spoken (seven seconds of speech in eight; in a talk, seven to ten seconds ahead of the speakers). So a converter delays the first word of a reply by its own delay, about a tenth of a second on a reply that now starts after about a second and a half, and after that only has to keep up.
- **Stopping is untouched.** When someone cuts in, Stand stops by dropping what is queued for the speakers. That happens on this Mac, after the converter.
- **One seam in the code.** Speech leaves the session as pieces of 24 kHz sound (`StandSession.onSpeech`) and goes to the speakers (`AudioIO.play`). `SessionController.start` joins the two, and so does the rehearsal's out-loud mode. A converter goes between them.
  - It must give back as much sound as it was given. The session keeps count of what has been heard by the length of what it sent (`playUntil`), and tells Stand its last words heard from that.
  - Its delay belongs in that count.
  - The recording of a run (`stand.wav`) would be of the voice before conversion unless the converted sound is what is kept.

## The catches

- **How it sounds is unknown.** Converters can smear a laugh, a breath, an emphasis, and those are what the user cares most about ("how it speaks is the gold"). Only a person's ear can judge it.
- **It changes the voice, not the delivery.** The accent, the rhythm and the pronunciation stay those of the stock voice. The result would be the user's voice speaking the way Kore or Charon speaks. People who know them may find that odd.
- **A good likeness takes material.** The models that take a voice from a short clip give a weaker match. The others want ten minutes or more of clean recordings and a training run.
- **It is one more thing running during a call**, next to the call itself.
- **The risk the vendors avoid becomes ours.** For the user's own voice, with Stand still saying that it is Stand, that is their call to make. For anyone who has not agreed, no.

## What a first try would be

About half a day. It needs nothing from the user until the listening.

1. Take `stand.wav` from a north-star run.
2. Convert it on this Mac with one or two of the above, to the voice the model ships with. Measure how fast it runs against real time and how long the first sound is delayed.
3. `poc/src/listen.js` can say whether the words survived. Give the user the two files, before and after, to say how it sounds.
4. Only then, and only if they say so, their own voice, from a recording they make for the purpose. Never from a session's recording: the one of 2026-11-13 at 11:20 has another person's voice in it.

## Sources

- [Voice replication, Gemini API](https://ai.google.dev/gemini-api/docs/voice-replication)
- [Voice design, Gemini API](https://ai.google.dev/gemini-api/docs/voice-design)
- [Configure language and voice, Live API on Google Cloud](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/configure-language-voice)
- [Forum: replicated_voice_config is accepted but ignored on gemini-3.8-live with an API key](https://discuss.ai.google.dev/t/gemini-3-8-live-replicated-voice-config-is-accepted-but-ignored-on-the-gemini-developer-api-api-key/189199)
- [OpenAI: how Voice Engine works and our safety research](https://openai.com/index/expanding-on-how-voice-engine-works-and-our-safety-research)
- [GPT-4o system card: voice impersonation and cloning risk](https://conductatlas.com/platform/openai/gpt-4o-system-card-pdf/voice-impersonation-and-cloning-risk/)
- [TechCrunch: a year later, OpenAI still hasn't released its voice cloning tool](https://techcrunch.com/2025/03/06/a-year-later-openai-still-hasnt-released-its-voice-cloning-tool)
- [Ultravox: voice cloning](https://docs.ultravox.ai/voices/cloning.md)
- [LLVC: Low-latency Real-time Voice Conversion on CPU](https://arxiv.org/pdf/2311.00873)
- [MeanVC 2 model card](https://huggingface.co/erenyeager-1/MeanVC2)
- [w-okada voice changer](https://www.github.com/w-okada/voice-changer/blob/master/README_en.md)
- [StreamVC poster](https://google-research.github.io/seanet/stream_vc/poster/streamvc_poster.pdf)
- [Seed-VC, a write-up](https://blog.brightcoding.dev/2025/09/28/real-time-zero-shot-voice-conversion-and-cloning-inside-the-seed-vc-framework)
