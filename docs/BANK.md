# Question banks (التحصيلي and القدرات)

Two files bundled in the IPA: `bank/tahsili.json` and `bank/qudurat.json`, with any pictures in `bank/images/`.
The app reads them with `Bank.load` (`ios/Revisal/Bank/Bank.swift`) and shows «يُجهَّز» while a bank has no questions.

## Format

```json
{
  "track": "qudurat",
  "version": 1,
  "sections": [{"id": "verbal", "name": "اللفظي"}, {"id": "quant", "name": "الكمي"}],
  "questions": [
    {
      "id": "q-000001",
      "section": "verbal",
      "skill": "التناظر اللفظي",
      "text": "قلم : كتابة",
      "options": ["مقص : قص", "باب : خشب", "ماء : بحر", "شمس : نهار"],
      "answer": 0,
      "explanation": "القلم أداة الكتابة، والمقص أداة القص.",
      "image": null,
      "source": "<file name> ص 12"
    }
  ]
}
```

- `sections`: التحصيلي `math`, `physics`, `chemistry`, `biology`; القدرات `verbal`, `quant`.
- `id` is unique and never reused, so a student's progress (`bankSeen`) survives a bank update.
- `options` are exactly four different texts, `answer` is 0-3, `explanation` says why the answer is right.
- `image` is a file name in `bank/images/` for a figure, table or graph the text alone cannot carry (quantitative questions especially); the stem may then be short.
- `skill` is the question's own type (e.g. التناظر اللفظي, إكمال الجمل, الخطأ السياقي, استيعاب المقروء, المفردة الشاذة; الحساب, الهندسة, الجبر, تحليل البيانات, المقارنة), so a draw spreads over skills.

## Checks

`RevisalCheck --bank-check bank` (run by `build-ipa.yml`) refuses an unknown section, a repeated id, options that are not four different texts, an answer outside 0-3, a question without an explanation, and a missing image. A broken bank never ships.

## Building the banks (the last step)

The owner adds the PDFs to `المصادر/` (outside Git). Every question of every file goes into the bank, with its explanation and, where needed, its figure. The build runs on the PC; any model it uses goes through the guardian's gateway (read `C:\Users\abdul\Documents\Claude\ClaudeHome\ai-models.md` first). New files only add questions with new ids.

The owner's Qudurat source (2026-11-01): the education administration's Drive folder, updated weekly:
https://drive.google.com/drive/folders/1q2mlCOTMkRXjPNizFKqjBPZAGbVS69iC
On 2026-11-01 it asked for a Google sign-in in the browser and was not found through the owner's Drive connector, so its files must be downloaded by the owner or the folder added to their Drive.
