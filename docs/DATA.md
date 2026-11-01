# What the phone stores

Everything is on the phone, in `Application Support/Revisal/`:

- `store.json` — one `StoreFile` (`ios/Revisal/Model/Store.swift`):
  - `books`: each curriculum book (`id` = first 8 bytes of the PDF's SHA-256, `name`, `subject`, `pages`, `units`).
    A unit has its pages, the `skills` the AI listed for it, `asked` (skill -> questions written) and `stems`
    (normalised stems already asked, at most 400) so new reviews aim at the least-asked skills and never repeat.
  - `sets`: the reviews (at most 200): title, `source` (track, book and unit or bank section, count), questions,
    the student's `choices`, `finishedAt`.
  - `bankSeen`: per bank, the question ids seen in the current round.
  - `settings`: `explainEach` (the explanation right after each answer).
- `books/<id>.pdf` — the added books.
- `texts/<unitId>.txt` — a unit's text, read once (Gemini transcribes scanned pages), so later reviews cost one call.

Decoders are lenient: a missing key takes its default. The backup (`Backup.swift`) zips the whole folder; a restore needs a `store.json` with `books`. AI keys are in the Keychain (service `io.github.ibnkabed.revisal`), never in the backup.
