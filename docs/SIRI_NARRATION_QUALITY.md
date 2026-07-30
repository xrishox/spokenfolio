# Siri narration quality research

This document records known and suspected narration failures at the EPUB-to-Siri
boundary, the evidence behind them, and the gates for any future production
change. It is a research and decision record, not a normalization specification.

- Research date: 2026-07-17
- Starting repository commit: `9c6dc2a`
- Private synthesis path: `siri/siri-private` through `SiriPrivateTTSBridge`
- Scope: English-first investigation, with multilingual hazards called out where
  they affect safe rule design
- Exclusion: these observations do not automatically generalize to macOS-27+
  `siri-fm/siri-expressive`; that model and its presets require separate,
  identity-bound measurements

No rule in this document is active merely because it is listed. The current
production behavior remains authoritative.

## Non-negotiable standard

A narration change is acceptable only when it is a strict upgrade:

1. it addresses a generalized phenomenon rather than a named book, publisher,
   title, path, hash, or excerpt;
2. it has positive evidence from synthetic fixtures and the real corpus;
3. uncertain cases preserve the original source form;
4. a complete old/new corpus comparison has zero unexplained changes;
5. every intended change is reviewed in context;
6. unchanged books and unaffected regions remain byte-identical; and
7. ReadAloud coverage, identity, and timing do not regress.

An unexplained regression rejects the candidate. It is not follow-up work.

## Evidence states

Claims use two independent labels: an evidence level and a lifecycle state.

### Evidence levels

| Level | Evidence | Permitted use |
|---|---|---|
| E5 | Repeated private-engine reproduction tied to exact runtime/voice identity, plus a matching real-corpus occurrence | May support a production proposal after all corpus and alignment gates |
| E4 | Repeated synthetic reproduction through SpokenFolio's private engine path | Establishes private-engine behavior, but not corpus prevalence |
| E3 | Deterministic repository/code evidence or reproducible real-EPUB structural evidence | Supports extraction candidates; does not establish Siri behavior |
| E2 | Official documentation, a format specification, professional standard, research paper, or inspectable behavior in another tool | Defines capabilities and design patterns, not this private engine's behavior |
| E1 | Public AVSpeech, Spoken Content, accessibility, forum, issue, or anecdotal report | Generates probes only |

### Lifecycle states

- **Research observation:** externally sourced or statically established, but
  not reproduced through the current private bridge.
- **Private-engine measurement:** executed through SpokenFolio and bound to the
  runtime identity required by the measurement schema; the result may be
  positive, negative, or inconclusive. "Reproduced" is reserved for a positive
  E4/E5 finding after paired review.
- **Candidate rule:** a generalized proposal that is inactive.
- **Approved production change:** a separately approved candidate that passed
  every applicable gate.

Public AVSpeech and system Spoken Content use related Apple technology, but they
are not substitutes for private-path measurements.

## Current boundary

The EPUB path is deliberately structural:

1. `EPUBKit` parses bounded XHTML and emits locator-bearing
   `PublicationBlock`s.
2. `AudiobookKit` selects sections, plans chapters, and creates plain-string
   narration paragraphs and bounded request units.
3. `SiriTTSCore` sets a plain `NSString` as the private request's `text` value.
4. ReadAloud transcribes the resulting audio and aligns it against the original
   EPUB.

Relevant boundaries:

- `Sources/EPUBKit/Extraction/NarrationExtractor.swift`
- `Sources/EPUBKit/Extraction/NoteDetection.swift`
- `Sources/EPUBKit/Extraction/ApparatusNumberDetection.swift`
- `Sources/AudiobookKit/Extraction/NarrationModel.swift`
- `Sources/AudiobookKit/Pipeline/SentenceSynthesizing.swift`
- `Sources/SiriTTSCore/Bridge/SiriPrivateTTSBridge.swift`
- `Sources/ReadAloudKit/ReadAloudInspector.swift`

The model stores source text plus one block-level locator. It has no alternate
spoken form, IPA span, lexicon reference, or reversible rewrite record.
Timeline-enabled audiobook production retains validated UTF-16 engine
word/segment anchors against the exact input and PCM timebase when available.
FM currently returns none, so it retains exact whole-utterance spans and exact
independently synthesized fallback-piece boundaries; it never invents token
boundaries or interpolates missing anchors. A lexical rewrite
immediately before synthesis would therefore make `export-text` cease
to describe the exact engine input and could make the spoken audio disagree with
the XHTML that stalign must align.

## Apple behavior and control surfaces

### What Apple documents

Apple's public AVFAudio API supports an attributed utterance with
`AVSpeechSynthesisIPANotationAttribute`, intended in part for proper names
[A1, A2]. `AVSpeechUtterance(ssmlRepresentation:)` accepts SSML on current
systems and returns `nil` for invalid input [A3]. Apple's WWDC example
specifically demonstrates `<speak>`, `<break>`, and rate-oriented `<prosody>`
[A4]. Apple does not publish a complete supported-element matrix for built-in
voices, so acceptance does not prove that every W3C element has its intended
audible effect.

The old macOS `NSSpeechSynthesizer` supports pronunciation and abbreviation
dictionaries, spelling-to-phoneme entries, and `phonemes(from:)` [A5]. Apple
deprecated it in macOS 14 in favor of `AVSpeechSynthesizer`; no equivalent
persistent pronunciation-lexicon registration API was found on the modern
public API.

Accessibility attributed-string keys cover IPA, language, spelling, and
punctuation for VoiceOver and announcements [A6]. They must not be assumed to be
general AVSpeech controls, and neither public attributed strings nor public
SSML are used by the current private bridge.

### What Apple discloses about normalization

Apple's TTS research describes a front end that expands numbers and
abbreviations, analyzes syntax, assigns stress and phrasing, and predicts a
phonetic transcription for words before synthesis [A7, A8]. Apple's separate
on-device synthesis work describes the neural acoustic and waveform path [A9].
The published work supports the conclusion that normalization and pronunciation
are context-dependent model problems. It does not disclose the rules or model
revision used by current macOS Siri natural, neural, or Gryphon assets, nor its
accuracy on rare names and audiobook prose.

### What the private framework suggests

Unofficial macOS 26.4 headers show a `SiriTTSSynthesisEngineRequest` with plain
text, rate, pitch, volume, profile, prompt style, and neural-prosody properties,
but no named IPA, phoneme-input, SSML, or lexicon property [P1]. Other private
headers expose text-to-phoneme requests and internal normalized-text and
replacement messages [P2-P5]. This establishes that the framework contains
normalization machinery. It does not establish a stable caller-controlled
phoneme-to-speech path, an SSML contract for the `text` property, or a
pronunciation dictionary.

Private interfaces remain unsupported and can change with macOS, framework, or
voice assets. Measurements must therefore include all three identities.

## Investigation class 1: potential extra speech

### High-confidence structural candidates

| Phenomenon | Current behavior and evidence | Risk in changing it |
|---|---|---|
| Visual bullets and ornaments | Leading bullets and decoration-only tokens are removed. The project historically observed `•` reaching Siri as spoken "comma" in an *A Dance with Dragons* appendix [R1]. The historical observation predates this measurement contract and must be rerun before receiving E4/E5 status. | Broad symbol deletion can remove semantic math, editorial marks, Catalan/Japanese middle dots, emphasis, or meaningful daggers. |
| Fragment-scoped notes or promotion | Document-level classification intentionally keeps a shared XHTML document when only one fragment is notes/index/promotion. Nonsemantic apparatus under that fragment can remain narratable [R2, E3]. | Excluding the whole document loses story prose; a safe fix needs fragment/range ownership. |
| Ruby annotations | `ruby`, `rt`, and `rp` are all inline elements, so base text and pronunciation annotation can be concatenated [R3, E3]. | Some languages need the annotation, some need the base, and some ruby conveys meaning rather than pronunciation. |
| Visible page furniture | Semantic page breaks and empty `page_16`-style anchors are silent. Visible page numbers, running heads, and unrecognized page spans remain [R4, E3]. | Isolated numbers and repeated headings can be legitimate prose, poetry, chapter labels, or intentional running motifs. |
| Repeated boilerplate inside primary XHTML | Whole-document front/back matter classification is conservative, but `<header>`, `<footer>`, publisher slogans, rights notices, and repeated navigation text inside chapters are not generally removed [R5, E3]. | Refrains, epigraphs, recurring headings, letters, and liturgical repetition are legitimate. Repetition alone is insufficient. |
| Tables | Cell text is retained as independent paragraphs without row/column semantics [R6, E3]. | Prose-like tables may read acceptably; data tables need an authored listening order or description. Dropping all tables loses content. |
| URLs and email | Visible link labels and literal URLs are retained. `href` destinations are not spoken [R7, E3]. | A URL can be a citation, plot content, contact instruction, code, or disposable marketing. Omit/alias/spell is a content-policy choice. |
| Attached markers and symbols | Plain daggers, asterisks, emoji, currency, operators, and prose-attached decoration can reach Siri [R8, E3]. | Most symbol classes also have legitimate spoken meanings. |

### Engine-originated extra speech to probe

Developer reports describe isolated capitals spoken descriptively (for example,
"Capital A") [B1], Roman-numeral letters receiving unintended readings [B2],
and a voice fallback that spoke markup-like parameters before fallback speech
[B3]. These are E1 observations from public AVSpeech, accessibility, or app
contexts. They justify probes for short tokens, markup-like strings, wrong voice
assets, and fallback paths; they do not establish behavior in
`SiriTTSService.framework`.

### Professional quality bar

There is no universal rule that all apparatus is silent. The Library of
Congress NLS standard generally preserves the source, explicitly introduces
notes, describes meaningful visual material, and documents omissions [N1, N2].
Other publisher guidance may omit footnotes, citations, appendices, and visual
references [N3]. EPUB semantics are strong evidence, but not sufficient proof
that omission is harmless: publishers can misuse semantics, and meaningful
visual content may require description or relocation. Every omission still
requires the product policy, corpus, and contextual-review gates.

## Investigation class 2: potential dropped speech

### Known project observation

A historical project observation reported a drop-capped standalone first word
disappearing, for example `A thousand ships` becoming `thousand ships`. It
awaits an identity-bound rerun. Ordinary inline spans are joined by the
extractor, so a normal `<span>A</span> thousand ships` shape should still produce
the leading word [R3]. The failure must be localized with exact XHTML,
engine input, audio, and runtime identity before assigning it to extraction,
Siri normalization, chunking, ASR, or alignment. The probe catalog includes
minimal drop-cap and isolated-capital pairs.

### Structural omissions that may or may not be defects

- `figure` and `figcaption` subtrees, image alt text, SVG, and media fallbacks are
  always dropped [R9, E3]. This prevents visual noise but can omit meaningful
  captions or descriptions.
- `aria-hidden="true"` is always silent; visually hidden text is used only as a
  bounded media-page fallback [R10, E3]. Publisher misuse can therefore hide
  real prose, while narrating every hidden layer would duplicate many fixed-layout
  books.
- Note and page semantics deliberately remove content. Incorrect publisher
  semantics can create source loss, but ignoring authoritative semantics would
  regress well-formed books.

These need audit findings and policy decisions, not unconditional reversal.

### Engine, boundary, and delivery candidates

Public reports associate dropped paragraphs with neural voices, em dashes,
unusual punctuation, and URL-like text [B6, B7]. Separate AVSpeech reports cover
voice-resource, no-audio, freeze, crash, and voice-dependent failures [B4], plus
buffer-enqueue errors where audio may still be written [B5]. They cover Spoken
Content or public AVSpeech on other OS versions. The private probe matrix must distinguish:

1. text never extracted;
2. text changed before synthesis;
3. request-unit or sentence-boundary context loss;
4. engine front-end token loss;
5. no-audio, partial-audio, or worker failure;
6. ASR failing to recognize audio that was present; and
7. stalign failing to attach audio that was present.

Sentinel words before and after the suspected trigger are mandatory. Duration,
audio digest, direct listening, and independent transcript evidence should be
recorded separately.

### Current alignment blind spots

ReadAloud section totals use filtered `EPUBImporter` blocks, while fragment text
and largest uncovered runs use much rawer DOM text [R11, E3]. Raw fragment text
can include note markers, hidden content, figure captions, or page furniture
that narration extraction intentionally removed. Covered counts are then
clamped to the filtered denominator. This can hide overcounting or create false
omission evidence. Production tokenization also splits apostrophes and uses the
current locale [R12, E3]. These audit issues must be repaired before ReadAloud is
used as the decisive gate for lexical spoken-form rewrites.

## Investigation class 3: potential incorrect speech

### Capitalization, acronyms, and isolated letters

The project preserves source case. A historical project observation reported
an all-caps fantasy name being spelled letter by letter instead of spoken as
words. It awaits an identity-bound E4/E5 rerun and is not yet a production-rule
basis. A global lowercase rule is unsafe:

- `NASA`, `FBI`, `US`, `IT`, `I`, and `A` represent different token classes;
- headings may be all caps for presentation but ordinary lexical text in source;
- small caps may be encoded through CSS rather than source case; and
- fantasy names may intentionally contain acronyms or initialisms.

Other TTS systems explicitly distinguish abbreviations, capitals, all-caps
words, and lexical acronyms [O5]. A future candidate needs contextual token
classification and a source-to-spoken mapping, not a case regex.

### Proper names, invented words, and foreign terms

ACX recommends pronunciation guidance for ambiguous names, fictional places,
fabricated names, and invented languages [N4]. Apple's public IPA attribute cites proper names as a use case [A1], but
that control is not present on the current private request. A spelling-only
replacement dictionary is also insufficient for names whose pronunciation
changes by language or character context.

A rights-holder or user may supply a per-edition pronunciation guide as an
explicit, opt-in authored override. That workflow is outside the strict-upgrade
process for automatic production rules: it may use a general lexicon mechanism,
but it must never become a hidden runtime exception, corpus-specific default,
or named-book check in code.

### Homographs

Words such as `read`, `lead`, `wind`, `record`, `present`, `content`, `object`,
`produce`, and `refuse` require syntax, tense, or part-of-speech context.
`ttstokenizer` carries part-of-speech-sensitive homograph entries [O4]. A global
word-to-pronunciation dictionary will necessarily be wrong in some currently-good
sentences. Homograph work is no-go without contextual classification or an
explicit reviewed override.

### Roman numerals

`IV` can mean four, the fourth, the letters I-V, intravenous, or part of an
identifier. The Sound Advice guideline recommends speaking Roman numerals as values but
calling out the notation when it matters, for example "page Roman two" [N5]. A
safe candidate must distinguish at least:

- `Chapter IV` or `Part IV`;
- `Henry IV`;
- `World War II`;
- `IV therapy`;
- standalone `I`, `V`, or `X`; and
- ordinary words composed only of Roman-numeral letters.

KittenTTS makes Roman conversion opt-in and context-guarded [O1]. SpokenFolio's
existing Roman handling is limited to title deduplication and a narrow ASR-side
heading repair; it does not normalize Siri input [R13].

### Abbreviations and sentence context

`abbr` contributes visible text while its `title` expansion is ignored. There
is no production abbreviation dictionary [R14, E3]. `Dr.`, `St.`, `No.`,
`Fig.`, `pp.`, initials, measurements, and `U.S.` are context-sensitive.
KittenTTS expands them by class and records spans for many replacements [O1].
Pandrator instead emphasizes inspectable raw/cleaned artifacts, stable blocks,
and diffs rather than exact source-to-normalized spans [O2].

Sentence splitting is another variable. HTTP speech is split into separate Siri
utterances, while audiobook paragraphs normally remain one utterance. Splitting
at an abbreviation can remove context and alter both pronunciation and prosody.
Every abbreviation probe therefore has split and unsplit modes.

### Numbers and semiotic classes

The repository does not choose how to speak years, dates, times, ranges,
decimals, fractions, currencies, units, versions, phone numbers, addresses, or
scientific notation [R15, E3]. SpokenFolio currently delegates these forms
unchanged to the private engine; its exact normalization behavior remains
unmeasured. These forms must be classified before verbalization:

- `2024` may be a year, count, identifier, or address;
- `3:05` may be a time, ratio, verse reference, or score;
- `10–12` may be a numeric range, date range, pages, or a dash-separated phrase;
- `1.2.3` may be a version, outline number, or malformed decimal;
- `St.` may mean Saint or Street; and
- `No.` may mean number or the word "no."

KittenTTS and NeMo treat these as separate semiotic classes and combine
contextual and deterministic normalization [O1, O7]. One general "numbers to
words" pass is not a safe candidate.

### Symbols and mathematics

Professional accessible-audio guidance gives conventional names for familiar
symbols, but notation-sensitive material often requires a more explicit reading
[N5]. The *Antifragile* subscript-math near-miss in this repository demonstrates
why styled small numbers cannot be removed merely because they resemble note
apparatus [R16]. Math, chemistry, currency, percentages, ranges, and decorative
punctuation require different rules.

## Other systems: useful patterns, not drop-in policy

### KittenTTS

KittenTTS has deterministic English normalization for numbers, years, currency,
percentages, dates, times, units, ranges, URLs, email, document abbreviations,
and opt-in Roman numerals. It records spans for many replacements relative to
Unicode-normalized input and tests forms such as
`Dr. Rivera paid $12.50 at 3:05 p.m.` [O1]. Those spans are not complete exact
source-to-spoken correspondence for every transformation, including whitespace
normalization. This is a useful architecture, not evidence that its English
expansions are correct for all books or for Siri.

### Pandrator

Pandrator separates source cleaning, footnote/citation/illustration handling,
all-caps and punctuation processing, deterministic or NeMo normalization, and
editable review artifacts. It protects acronyms and Roman numerals during
optional all-caps normalization and falls back to source on exceptions, empty
output, or exposed internal token markup [O2]. This is a useful limited failure
guard, but it does not detect fluent semantic errors, preserve exact spoken
mappings, or satisfy SpokenFolio's corpus-wide strict-upgrade gate.

### epub_to_audiobook

`p0n1/epub_to_audiobook` offers optional endnote/reference removal, regex
substitution, previews, and processed-text export [O3]. Its flexibility is
useful for manual production, but broad regexes are structurally less safe than
SpokenFolio's EPUB-semantic approach and are not suitable as global defaults.

### Dictionary and normalizer systems

`ttstokenizer` uses pronunciation dictionaries and part-of-speech-sensitive
homographs [O4]. eSpeak NG dictionaries support contextual rules,
abbreviations, capitalization conditions, phrase pronunciations, and number
fragments [O5]. OpenTTS exposes a documented SSML subset with `say-as`, `sub`,
and `break` [O6]. NeMo combines neural context with deterministic WFST rules
where fluent but semantically wrong output is costly [O7].

The recurring safe architecture is:

1. preserve document structure;
2. classify the phenomenon;
3. transform only high-confidence cases;
4. retain exact source/spoken correspondence;
5. make transformed text inspectable;
6. fall back to source on uncertainty;
7. synthesize; and
8. verify audio and alignment independently.

## Ranked future candidates

This is a provisional investigation order, not an implementation approval.
Upside estimates describe impact *if the phenomenon is present*; G0 work must
measure corpus prevalence and private-engine behavior before ranks 1–9 can
become fix priorities. "Prerequisite" items improve evidence and do not alter
narration.

| Rank | Candidate | Estimated upside | Regression risk | Required before proposal |
|---:|---|---|---|---|
| G0 | Canonical old/new corpus manifests and comparator | Essential: makes "zero unexplained changes" enforceable | Low | Deterministic corpus identity, options, section/chapter/unit/source-locator comparison, exact narration digests, and strict expected-difference files |
| G0 | Align ReadAloud's filtered denominator and fragment/run text; make token folding deterministic | High: makes the alignment gate trustworthy | Low-medium because audit verdicts may change | Separate audit-policy proposal and corpus re-audit; no narration behavior change |
| G0 | Private Siri probe runner/results bound to runtime and voice identity | High: separates Apple anecdotes from this path | Low | Probe catalog, measurement schema, repeated runs, audio digest/duration, direct and ASR review |
| 1 | Fragment-scoped apparatus ownership | Potentially high on affected shared documents; prevalence unmeasured | Medium | New fragment/range representation; positive and adversarial fixtures; complete corpus diff |
| 2 | Ruby base/annotation policy | Potentially high on affected multilingual documents; audible impact unmeasured | Medium-high, language dependent | Classify ruby shapes and language; private-path probe; corpus occurrence; preserve mapping; no universal base-only or annotation-only behavior |
| 3 | Visible page furniture detection | Potentially high on affected print-replica EPUBs; prevalence unmeasured | High | Multiple structural and repetition signals; protect chapter numbers, poetry, dates, and intentional labels |
| 4 | Repeated in-chapter boilerplate detection | Potentially medium-high; prevalence unmeasured | High | Publisher/navigation/DOM corroboration; repetition alone forbidden |
| 5 | Narrow, separately versioned Roman-heading or abbreviation candidates | Unknown until private probes and corpus prevalence are measured | High | E4 private reproduction, source/spoken mapping, unchanged negative corpus, ReadAloud proof |
| 6 | All-caps lexical classification and reviewed pronunciation data | Unknown until the historical observation is reproduced and prevalence measured | Very high | Distinguish words/acronyms/initialisms/headings/isolated letters; explicit fallback; no global lowercase rule |
| 7 | Contextual number and URL normalization | Unknown; potentially broad if specific private defects reproduce | Very high | Separate semiotic classes, explicit policy, span mappings, private probes, corpus and alignment gates |
| 8 | Structure-aware table narration | Policy-dependent benefit on affected books | Very high | Authored or inferable reading order and mapping; prose-table negative fixtures |
| 9 | Homograph lexicon or general pronunciation override | Targeted, prevalence unmeasured | Very high | Backend-neutral reviewed lexicon design and context-sensitive authority; unsupported by current private request |

Figure, note, citation, appendix, acknowledgment, table, and URL inclusion or
omission can be an explicit product or per-edition policy. Such choices sit
outside the automatic strict-upgrade ranking because they may intentionally
remove authored content and are not universally better.

## Explicitly rejected approaches

- Book-title, publisher, path, hash, or excerpt checks in production logic.
- Global deletion of numbers, superscripts, brackets, URLs, symbols, notes,
  tables, figures, appendices, or acknowledgments.
- Global lowercasing of all-caps text.
- Global Roman-numeral conversion.
- Global word-to-pronunciation substitution for homographs.
- Treating public AVSpeech IPA or SSML as available to the private request.
- Treating a public issue report as proof of current private-engine behavior.
- Letting a neural or LLM normalizer silently rewrite source text.
- Accepting a corpus diff because the changed books "look expected" without an
  exact, candidate-specific expectation and surrounding-context review.
- Using an expectations file as a runtime exception list.

## Private-engine probe protocol

`docs/siri-narration-quality/probe-catalog.json` defines synthetic trigger and
control inputs. The stable control identifier is `<probe-id>#control`; each
measurement declares whether it exercised the trigger or control arm and must
link the paired measurement ID.

A measurement must conform to
`docs/siri-narration-quality/measurement.schema.json` and pass a future semantic
validator. JSON Schema cannot enforce every cross-field invariant. The validator
must require a clean recorded commit; matching repetition/run counts; unique
contiguous run numbers; correct UTF-8 digests; exact catalog input resolution;
even PCM byte counts; and duration agreement with mono 48 kHz signed 16-bit PCM.
It must also verify reciprocal pair links, opposite trigger/control variants,
and identical probe, catalog, repository, runtime, voice, and request-mode
identities across the pair. Every catalog-required assessment method must appear
in `performedAssessmentMethods`; claiming `transcript` additionally requires
independent transcript evidence for the runs.

Run each probe at least three times per runtime/voice identity. Where segmentation
may matter, run both:

- `audiobook-unsplit`: worker-side sentence splitting disabled and input capped
  at 4,000 Swift `Character`s; and
- `http-split`: worker-side sentence splitting enabled and input capped at 4,096
  Swift `Character`s.

Each omission-risk probe includes fixed, distinguishable before/after sentinels.
Record the exact input, audio digest and duration, observed spoken form, performed
assessment methods, arm result, and confidence. Schema validity is not a
privacy approval: only synthetic measurements are eligible to be committed, and
reviewer IDs must be pseudonymous. Do not commit audio, PCM, credentials, Apple
voice assets, purchased EPUBs, real-book input, full transcripts, or sensitive
notes.

An individual arm record contains an observation result, not a reproduction
verdict. Paired review compares trigger and control records and derives
`reproduced-private`, `not-reproduced-private`, or `inconclusive`. The measurement
record does not assign E4 or E5. Evidence review may assign E4 only to repeated
positive private-path reproduction. E5 additionally requires a
separate bounded real-corpus occurrence record containing hashes, locators, and
review confirmation without book text. A public AVSpeech run requires a separate
public-control record and remains E1 for the private-path claim.

## Corpus comparison contract for future changes

The current `audiobook audit` command runs the production importer, planner,
sentence splitter, and request-unit planner and exports exact narration, but it
does not compare old and new runs. Before the first narration candidate, add a
canonical run manifest and comparator with these properties:

1. Bind repository commit, executable digest, policy versions, planning options,
   and a corpus manifest.
2. Match books by full EPUB SHA-256 rather than basename.
3. Compare import failures and warnings, section roles and inclusion decisions,
   chapter order and titles, announcements, source locators, synthesis-unit
   boundaries, filenames, and exact narration bytes.
4. Detect added, removed, changed, or reordered books and chapters.
5. Require an explicit expectations file containing candidate ID, source hash,
   exact old/new digests, reason, and evidence IDs.
6. Fail when a difference is unexplained, an expected difference is absent, one
   change matches multiple expectations, or an expectation is stale or broad.
7. Retain bounded summaries and hashes, not corpus text.

For each candidate, build baseline and candidate binaries from recorded clean
commits, run them with identical options over the same immutable corpus, verify
source hashes before and after, compare the complete narration trees, and review
every changed paragraph plus surrounding unchanged context.

## Go/no-go gates

### Evidence gate

- Structural candidates require a synthetic fixture and at least one real-corpus
  occurrence.
- Siri-behavior candidates require repeated private-path reproduction tied to
  exact macOS, framework, and voice identities.
- The rule must describe an input class without naming a book or edition.

### Rule-design gate

- The predicate is deterministic, bounded, inspectable, and language-aware where
  needed.
- Ambiguous cases preserve source text.
- Policy-dependent omissions are explicit configuration or are rejected.
- Spoken-form rewrites retain source-to-spoken correspondence.

### Test gate

Positive fixtures must be paired with adversarial negatives protecting ordinary
prose, chapter numbers, years, math, poetry, acronyms, cross-references,
legitimate repetition, identifiers, and multilingual text. Source locators,
section selection, chapter boundaries, and the 4,000-character request limit
must remain valid.

### Corpus gate

- Old and new runs use the same immutable corpus and options.
- The comparator reports zero unexplained changes.
- Every expected change is exact, candidate-specific, and manually reviewed.
- Unaffected books and unaffected regions remain byte-identical.
- No import, planning, source-integrity, or request-bound failure is added.

### ReadAloud gate

A lexical spoken-form rewrite is no-go until source-to-spoken mappings exist and
are consumed by alignment. Representative samples cannot waive this requirement.
Changed books must also produce no new missing-content, identity, timing,
compatibility, or structural finding.

### Release gate

- Bump `AudiobookPolicyVersions.extractorVersion` for extraction,
  classification, planning, or announcement changes.
- Bump `NarrationUnitPlanner.synthesisPolicyVersion` for synthesis-input or unit
  policy changes.
- Run `swift test`, `./scripts/check.sh`, the complete corpus comparison, a real
  audiobook smoke test, and the relevant private Siri probes on the release
  runtime.

## Repository evidence register

| ID | Evidence | Level |
|---|---|---:|
| R1 | `NarrationExtractor` comment and bullet/decoration tests; historical *A Dance with Dragons* appendix observation awaiting an identity-bound rerun | E3 structurally; private observation not yet promoted to E4/E5 |
| R2 | Fragment-only landmark behavior in `SectionClassifier` and chapter-planning tests | E3 |
| R3 | `ruby`, `rt`, and `rp` are ordinary inline elements; ordinary inline spans are concatenated | E3 |
| R4 | Semantic/empty page markers are silent; visible page furniture is not generally classified | E3 |
| R5 | Whole-document classification is conservative; in-chapter header/footer boilerplate has no general detector | E3 |
| R6 | Table cells become independent narration blocks without table semantics | E3 |
| R7 | Ordinary link labels and literal visible URLs remain prose | E3 |
| R8 | Decoration attached to prose and most symbol classes remain | E3 |
| R9 | Figures, captions, image alt text, SVG, and media subtrees are dropped | E3 |
| R10 | `aria-hidden` is silent; visual hidden layers are conditional fallbacks | E3 |
| R11 | ReadAloud totals use filtered blocks while fragment/run text uses rawer DOM text | E3 |
| R12 | ReadAloud tokenization splits on nonalphanumerics and uses `Locale.current` | E3 |
| R13 | Roman handling exists only for title dedupe and narrow ASR heading repair | E3 |
| R14 | `abbr` visible text is retained and its expansion is ignored | E3 |
| R15 | No general date/time/range/currency/unit/version normalization exists | E3 |
| R16 | Apparatus guards protect the *Antifragile* subscript-math near-miss; NRSVue and Popper shapes motivate true-positive rules | E3 |

### 2026-07-17 probe campaign (single-run private-path observations)

A hunting campaign (artifacts in `/tmp/alignment/hunt/`, mirrored findings in
its `FINDINGS.md`) ran single-pass private-path probes on Nora Natural,
macOS 26. Single runs do not meet the three-repetition bar, so these are
recorded as strong leads pending protocol-grade reruns:

| ID | Observation | Status |
|---|---|---|
| R17 | A narration unit containing no letters or digits (`—`, `____`, `......`, `.`, `-`, `···`, `)`) is refused by the engine (`synthesis_failed`) and aborts the whole `audiobook create` run; 536 such paragraphs across 28 corpus books. `º º º` and `…` synthesize (silent). **Addressed** (`synthesisPolicyVersion` 3): a refusal on a letterless-and-digitless unit falls back to silence; accepted speechless units keep engine audio. Policy 4 additionally retries a rejected speakable multi-sentence paragraph as bounded natural sentence pieces. Policy 7 recursively subdivides a rejected sentence or fallback piece at safe clause/whitespace boundaries, without internal silence; an unsplittable rejected token still fails instead of being altered. | Reproduced-private, single run; fix verified by synthetic-EPUB rebuild and full-corpus extraction identity |
| R18 | Some all-caps OOV names letter-spell (`SER`→"S-E-R", `ALAYAYA`→letters) while mixed-case twins speak correctly and other caps tokens (`TORNADO`, `LORD`, `GODRY`) speak as words; real-corpus appendix audio agrees across 2–3 ASR engines (incl. caps `ARYA`→"Uriah"). **Addressed** (`extractorVersion` 11): evidence-gated fold of presentational caps occurrences to the book's attested twin (measurement records: 3 deterministic runs per pair, byte-identical, in the hunt workspace); corpus A/B mechanically verified — 1,299 folded tokens across 68 books, every one a case-only fold to an attested twin, zero other changes. | E4: repeated deterministic private-path reproduction, identity-bound |
| R19 | Full URLs are verbalized including scheme and query operators ("colon slash slash", "equals"); 15.7 s for one citation URL. **Largely addressed** (`extractorVersion` 10): citation-table omission removes the endnote URLs that were the dominant source (one book: 965 URL paragraphs → 1); URLs in genuine prose remain narrated by policy. | Reproduced-private, single run; corpus A/B reviewed |
| R20 | Plain-text bracketed markers (`[12]`) surviving extraction are spoken as numbers. **Addressed** (`extractorVersion` 9): glued 1–3-digit marker chains in dense ascending runs of ≥5 are removed; IEEE/mid-sentence/standalone/4-digit/lettered brackets are structurally unreachable. | Reproduced-private, single run; corpus A/B reviewed |
| R21 | Cleared on this identity, single run: standalone/heading Roman numerals read as numbers; drop-cap leading word retained end-to-end; 3,809-char single utterance not truncated; caps common words not spelled; emoji, markdown symbols, curly quotes, fullwidth punctuation, phone numbers, unit/abbreviation misexpansions — no artifacts. | Not-reproduced-private, single run (public reports B1–B7 largely do not transfer) |
| R22 | Whisper (large-v3-turbo) silently collapses ~25 s windows of highly repetitive audio; audit metrics that rely on Whisper transcripts have a corresponding blind spot. | Tool observation, reproduced twice in one session |

## External evidence ledger

All sources were accessed on 2026-07-17.

### Apple primary sources

- **A1:** [AVSpeechSynthesisIPANotationAttribute](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisipanotationattribute) — public IPA attribute.
- **A2:** [AVSpeechUtterance](https://developer.apple.com/documentation/avfaudio/avspeechutterance) — public utterance contract.
- **A3:** [AVSpeechUtterance SSML initializer](https://developer.apple.com/documentation/avfaudio/avspeechutterance/init%28ssmlrepresentation%3A%29-8zam9) — public SSML entry point.
- **A4:** [WWDC 2023 speech synthesis and SSML](https://developer.apple.com/videos/play/wwdc2023/10033/) — demonstrated `<speak>`, `<break>`, and `<prosody>` behavior.
- **A5:** [NSSpeechSynthesizer](https://developer.apple.com/documentation/appkit/nsspeechsynthesizer) — deprecated macOS speech dictionaries and phoneme APIs.
- **A6:** [Speech attributes for attributed strings](https://developer.apple.com/documentation/uikit/speech-attributes-for-attributed-strings) — accessibility speech attributes.
- **A7:** [Deep Learning for Siri's Voice](https://machinelearning.apple.com/research/siri-voices) — Apple TTS front-end and neural voice overview.
- **A8:** [Scalable Multilingual Frontend for TTS](https://machinelearning.apple.com/research/scalable-multilingual-frontend-tts) — contextual text normalization and pronunciation research.
- **A9:** [On-device Neural Speech Synthesis](https://machinelearning.apple.com/research/on-device-neural-speech) — on-device synthesis architecture.
- **A10:** [App Review Guidelines 2.5.1](https://developer.apple.com/app-store/review/guidelines/) — public-API distribution rule; not a narration-behavior source.

### Unofficial private-framework evidence

- **P1:** [SiriTTSSynthesisEngineRequest header](https://github.com/thatmarcel/macOS-26.4-headers/blob/4d5d4f5eba9020ff6bf2879071d565dcce0f4db1/headers/SiriTTSService/SiriTTSSynthesisEngineRequest.h).
- **P2:** [SiriTTSPhonemeRequest header](https://github.com/thatmarcel/macOS-26.4-headers/blob/4d5d4f5eba9020ff6bf2879071d565dcce0f4db1/headers/SiriTTSService/SiriTTSPhonemeRequest.h).
- **P3:** [SiriTTSDaemonSession header](https://github.com/thatmarcel/macOS-26.4-headers/blob/4d5d4f5eba9020ff6bf2879071d565dcce0f4db1/headers/SiriTTSService/SiriTTSDaemonSession.h).
- **P4:** [Normalized-text message header](https://github.com/thatmarcel/macOS-26.4-headers/blob/4d5d4f5eba9020ff6bf2879071d565dcce0f4db1/headers/SiriTTSService/OPTTSTTSNormalizedText.h).
- **P5:** [Replacement message header](https://github.com/thatmarcel/macOS-26.4-headers/blob/4d5d4f5eba9020ff6bf2879071d565dcce0f4db1/headers/SiriTTSService/OPTTSTTSReplacement.h).

These headers are reverse-engineered observations, not supported contracts.

### Apple and community issue reports

- **B1:** [AVSpeech describes characters instead of only speaking them](https://developer.apple.com/forums/thread/707199) — isolated-capital and accented-character report.
- **B2:** [Roman numeral misreading](https://apple.stackexchange.com/questions/442424/508-accessibility-english-siri-misreads-certain-roman-numerals) — accessibility report.
- **B3:** [Extra markup-like speech after voice failure](https://developer.apple.com/forums/thread/730789) — fallback report, Feedback `FB12223340`.
- **B4:** [AVSpeechSynthesizer failures on iOS 17](https://developer.apple.com/forums/thread/738048) — voice/resource/no-audio reports.
- **B5:** [`write(_:toBufferCallback:)` errors](https://developer.apple.com/forums/thread/716424) — buffer-rendering report.
- **B6:** [Spoken Content paragraph skipping](https://discussions.apple.com/thread/255489297) — community report.
- **B7:** [Punctuation/URL-adjacent skipping](https://www.reddit.com/r/applehelp/comments/zuo8bc) — community report.

These are E1 probe sources and do not prove private-path behavior.

### Professional narration standards and guidance

- **N1:** [Library of Congress NLS Narration specification](https://www.loc.gov/nls/who-we-are/guidelines-and-specifications/contract-specifications/narration/) — fidelity, pronunciation, notes, and omissions.
- **N2:** [The Art and Science of Audio Book Production](https://www.loc.gov/nls/who-we-are/guidelines-and-specifications/the-art-and-science-of-audio-book-production/) — complete review, pronunciation research, and visual descriptions.
- **N3:** [Wesleyan Audiobook Narration Guide](https://dhjhkxawhe8q4.cloudfront.net/wespress-wp/wp-content/uploads/2024/02/15114315/Audiobook-Narration_Guide.pdf) — publisher house policy for notes, citations, and visuals.
- **N4:** [ACX Director's Notes](https://www.acx.com/mp/blog/directors-notes-for-your-acx-production) — pronunciation guides for ambiguous and invented vocabulary.
- **N5:** [Sound Advice Guidelines](https://printdisability.org/wp-content/uploads/2013/09/Sound-Advice-Guidelines-FINAL-VERSION-Jan-2014.pdf) — Roman numerals, symbols, abbreviations, and addresses.
- **N6:** [CDC Audio Script Writing Guide](https://tools.cdc.gov/medialibrary/docs/AudioScriptWritingGuide.pdf) — scripted spoken forms for percentages, units, dates, names, and URLs.

### Open-source tools and text-normalization research

- **O1:** [KittenTTS preprocessing](https://github.com/KittenML/KittenTTS/blob/9f3e0d8b6600b56ebe1b4d7b6d8e1e020077d1f2/kittentts/preprocess.py) and [normalization tests](https://github.com/KittenML/KittenTTS/blob/9f3e0d8b6600b56ebe1b4d7b6d8e1e020077d1f2/tests/test_text_normalization.py).
- **O2:** [Pandrator](https://github.com/lukaszliniewicz/Pandrator/tree/790f37391637492234feabf976beb8e76e26c0b7), including its deterministic cleaning and NeMo integration.
- **O3:** [`epub_to_audiobook`](https://github.com/p0n1/epub_to_audiobook/tree/b23f965881ace184c5a00c667bdbfe2117647b84) — optional endnote removal and substitutions.
- **O4:** [`ttstokenizer`](https://github.com/neuml/ttstokenizer/tree/b22abefecdd6052f893354720ebd2f3f91c3f8aa) and its [English homograph dictionary](https://github.com/neuml/ttstokenizer/blob/b22abefecdd6052f893354720ebd2f3f91c3f8aa/ttstokenizer/homographs.en).
- **O5:** [eSpeak NG dictionary documentation](https://github.com/espeak-ng/espeak-ng/blob/fbe4b3764285c35b1f035cb8d09ad9fc19f71c30/docs/dictionary.md).
- **O6:** [OpenTTS](https://github.com/synesthesiam/opentts/tree/60df7118d844ce8d879b48d1001bf3d3d36e6730) — documented SSML subset.
- **O7:** [NVIDIA NeMo text normalization](https://docs.nvidia.com/nemo-framework/user-guide/25.09/nemotoolkit/nlp/text_normalization/nn_text_normalization.html).
- **O8:** [Normalization of Non-Standard Words](https://www.clsp.jhu.edu/workshops/99-workshop/normalization-of-non-standard-words/) — foundational semiotic-class ambiguity.
- **O9:** [A Text Normalisation System for Non-Standard English Words](https://aclanthology.org/W17-4414/) — context-sensitive normalization research.
