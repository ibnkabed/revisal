"""يبني بنك القدرات من ملفات PDF في المصادر/القدرات (docs/BANK.md)؛ والتحصيلي حين تصل ملفاته.

    python tools/build_bank.py scan              حصر الملفات والصفحات، بلا نموذج
    python tools/build_bank.py read [--limit N]  يقرأ كل صفحة مصوّرة بـ Claude Haiku عبر بوابة الحارس
    python tools/build_bank.py tiles <folder> [--count N]  صور مجمّعة (حتى 6 صفحات) يقرؤها Claude في جلسة الاشتراك
    python tools/build_bank.py ingest <folder>   يحفظ ما كُتب في <folder>/answers/*.json قراءةً لكل صفحة
    python tools/build_bank.py write             يجمع الأسئلة ويحذف المكرر ويقص الرسوم ويكتب bank/*.json

- القراءة من رصيد الاشتراك (قرار المالك 2026-11-01): tiles يجمع الصفحات غير المقروءة في صور، يقرؤها Claude في الجلسة
  ويكتب لكل صورة ملفًا في answers/ بهذا الشكل: {"<رقم الصورة>-<رقم الصفحة فيها>": [[القسم v|q، المهارة، النص،
  [أ،ب،ج،د]، رقم الإجابة 0-3، [x0,y0,x1,y1] أو null], ...]}، ثم ingest يحفظها في .bank-cache كما تحفظها read.

- كل صفحة تُقرأ مرة واحدة: جوابها محفوظ في .bank-cache/<بصمة الملف>/<رقم الصفحة>.json، فالقراءة تستأنف من حيث وقفت،
  والملف الجديد وحده يُقرأ عند إضافته.
- الأسئلة بلا شرح (قرار المالك 2026-11-01): نص السؤال وخياراته الأربعة والإجابة الصحيحة المطبوعة في الصفحة فقط.
  والسؤال الذي لا تُطبع إجابته في صفحته يُترك.
- رقم السؤال بصمة نصه وخياراته، فلا يتغير بإعادة البناء، ويبقى تقدّم الطالب في البنك بعد التحديث.
- النموذج من بوابة الحارس وحدها (http://127.0.0.1:8741)، وكل طلب يُسجَّل فيها.
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pymupdf

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "المصادر"
CACHE = ROOT / ".bank-cache"
BANK = ROOT / "bank"
IMAGES = BANK / "images"
GATEWAY = "http://127.0.0.1:8741/v1/chat/completions"
PROJECT = "Revisal"
TASK = "استخراج أسئلة البنك"
READ_DPI = 110
FIGURE_DPI = 170
WORKERS = 4

# The files are Qudurat (owner, 2026-11-01), but some questions in them are Tahsili subjects: they go to that bank.
TRACK_OF_SECTION = {"verbal": "qudurat", "quant": "qudurat",
                    "math": "tahsili", "physics": "tahsili", "chemistry": "tahsili", "biology": "tahsili"}
SECTIONS = {"qudurat": [("verbal", "اللفظي"), ("quant", "الكمي")],
            "tahsili": [("math", "الرياضيات"), ("physics", "الفيزياء"), ("chemistry", "الكيمياء"), ("biology", "الأحياء")]}
LETTERS = {"أ": 0, "ا": 0, "ب": 1, "ج": 2, "د": 3, "a": 0, "b": 1, "c": 2, "d": 3}

SYSTEM = """You read one page of a Saudi Qudurat (القدرات) preparation PDF and extract its multiple-choice questions exactly as printed. Return JSON only:
{"questions":[{"text":"...","options":[{"label":"أ","text":"..."},{"label":"ب","text":"..."},{"label":"ج","text":"..."},{"label":"د","text":"..."}],"answer":"ب","section":"verbal","skill":"...","figure":false,"box":[0,0,1,1]}]}
Rules:
- Only complete questions with exactly four options. Copy the stem and options word for word, keeping Arabic-Indic digits, fractions and symbols; write math in plain text (e.g. ٣/٤ , س² , √٢).
- Each option keeps the label printed beside it: أ ب ج د, or a b c d (a=أ, b=ب, c=ج, d=د). Options are often in a right-to-left grid, so read each label, never the position.
- "answer" is the label of the correct option ONLY when the page itself shows it: a check mark √ or ✓ beside an option, a highlighted or coloured option, «الإجابة: ج», or an answer key on the page. If nothing on the page marks it, use null. Never solve the question yourself.
- "section": verbal (اللفظي: analogies, sentence completion, contextual error, reading, odd word) or quant (الكمي: arithmetic, algebra, geometry, statistics, comparisons, any mathematics).
- "skill": the question type in Arabic, short: e.g. التناظر اللفظي، إكمال الجمل، الخطأ السياقي، استيعاب المقروء، المفردة الشاذة، الحساب، الجبر، الهندسة، الإحصاء والاحتمالات، المقارنة.
- "figure": true when the question cannot be answered without a drawing, chart, table or diagram on the page; then "box" is that drawing's bounding box as fractions of the page width and height [x0,y0,x1,y1], excluding logos, headers and the answer bar. Otherwise false and omit box.
- A reading passage shared by several questions goes at the start of each question's text.
- Pages with no such questions (covers, lessons, laws, schedules, ads) return {"questions":[]}."""

lock = threading.Lock()


def out(*args):
    with lock:
        print(*args, flush=True)


def excluded() -> set[str]:
    """tools/bank-exclude.txt: files with no questions (schedules, summaries, Tahsili content), one per line."""
    path = Path(__file__).with_name("bank-exclude.txt")
    if not path.exists():
        return set()
    return {line.split("  #")[0].strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")}


ONLY: str | None = None   # --only القدرات: one source folder


def pdfs() -> list[Path]:
    skip = excluded()
    base = SOURCES / ONLY if ONLY else SOURCES
    return sorted(p for p in base.rglob("*") if p.suffix.lower() == ".pdf" and p.name not in skip)


def file_id(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def scan() -> None:
    files, pages, seen = 0, 0, {}
    for p in pdfs():
        fid = file_id(p)
        if fid in seen:
            out(f"مكرر: {p.relative_to(SOURCES)} = {seen[fid]}")
            continue
        seen[fid] = p.relative_to(SOURCES)
        n = len(pymupdf.open(p))
        done = len(list((CACHE / fid).glob("*.json"))) if (CACHE / fid).exists() else 0
        files += 1
        pages += n
        out(f"{n:5} صفحة، مقروء {done:5}  {p.relative_to(SOURCES)}")
    out(f"\n{files} ملفًا فريدًا، {pages} صفحة")


def page_jpeg(doc, i: int, dpi: int) -> bytes:
    return doc[i].get_pixmap(dpi=dpi).tobytes("jpeg", jpg_quality=80)


def ask(image: bytes) -> tuple[dict, dict]:
    body = {
        "model": "auto",
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(image).decode()}},
                {"type": "text", "text": "Extract the questions on this page as JSON."}]},
        ],
        "response_format": {"type": "json_object"},
        "max_tokens": 4000,
        "guardian": {"project": PROJECT, "task": TASK, "class": "json", "mode": "background",
                     "provider": "anthropic", "timeout": 180},
    }
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    last = ""
    for attempt in range(3):   # البوابة وحدها، ثلاث مرات في دقيقتين (ai-models.md)
        req = urllib.request.Request(GATEWAY, data=data, method="POST",
                                     headers={"Content-Type": "application/json; charset=utf-8", "X-Guardian": "1"})
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                reply = json.loads(r.read().decode("utf-8"))
            text = reply["choices"][0]["message"]["content"] or ""
            return parse(text), reply.get("guardian", {}) | {"usage": reply.get("usage", {})}
        except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as exc:
            last = getattr(exc, "code", None) or type(exc).__name__
            time.sleep(20 * (attempt + 1))
    raise RuntimeError(f"البوابة لم تُجب: {last}")


def parse(text: str) -> dict:
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    try:
        return json.loads(t)
    except ValueError:
        m = re.search(r"\{.*\}", t, re.S)
        return json.loads(m.group(0)) if m else {"questions": []}


def read(limit: int | None) -> None:
    jobs = []
    for p in pdfs():
        fid = file_id(p)
        n = len(pymupdf.open(p))
        for i in range(n):
            if not (CACHE / fid / f"{i + 1}.json").exists():
                jobs.append((p, fid, i))
    if limit:
        jobs = jobs[:limit]
    out(f"صفحات تُقرأ الآن: {len(jobs)}")
    totals = {"in": 0, "out": 0, "pages": 0, "failed": 0}
    started = time.time()

    def one(job):
        p, fid, i = job
        try:
            image = page_jpeg(pymupdf.open(p), i, READ_DPI)
            result, meta = ask(image)
        except Exception as exc:  # noqa: BLE001 — صفحة واحدة لا توقف الباقي
            with lock:
                totals["failed"] += 1
            out(f"فشل: {p.name} ص{i + 1}: {exc}")
            return
        (CACHE / fid).mkdir(parents=True, exist_ok=True)
        record = {"file": str(p.relative_to(SOURCES)), "page": i + 1, "questions": result.get("questions") or [],
                  "provider": meta.get("provider"), "model": meta.get("model")}
        (CACHE / fid / f"{i + 1}.json").write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        u = meta.get("usage") or {}
        with lock:
            totals["in"] += int(u.get("prompt_tokens") or 0)
            totals["out"] += int(u.get("completion_tokens") or 0)
            totals["pages"] += 1
            done = totals["pages"]
        if done % 25 == 0 or done == len(jobs):
            rate = (time.time() - started) / done
            out(f"{done}/{len(jobs)} صفحة، {rate:.1f} ث للصفحة، الرموز {totals['in']}/{totals['out']}")

    with ThreadPoolExecutor(WORKERS) as pool:
        list(pool.map(one, jobs))
    out(json.dumps(totals, ensure_ascii=False))


def norm(s: str) -> str:
    s = re.sub(r"[ًٌٍَُِّْـ]", "", s or "")
    s = s.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا").replace("ة", "ه").replace("ى", "ي")
    return re.sub(r"[^\w]+", " ", s.lower()).strip()


def clean(q: dict) -> dict | None:
    text = re.sub(r"\s+", " ", str(q.get("text") or "")).strip()
    raw = q.get("options") or []
    if raw and all(isinstance(o, dict) for o in raw):   # options carry their printed labels: put them in أ ب ج د order
        labelled = {LETTERS.get(str(o.get("label") or "").strip().lower()[:1]): o.get("text") for o in raw}
        if set(labelled) != {0, 1, 2, 3}:
            return None
        raw = [labelled[i] for i in range(4)]
    options = [re.sub(r"\s+", " ", str(o or "")).strip() for o in raw]
    letter = str(q.get("answer") or "").strip().lower()[:1]
    section = str(q.get("section") or "")
    if len(options) != 4 or any(not o for o in options) or len({norm(o) for o in options}) != 4:
        return None
    if letter not in LETTERS or section not in TRACK_OF_SECTION:
        return None
    if not text and not q.get("figure"):
        return None
    return {"text": text, "options": options, "answer": LETTERS[letter], "section": section,
            "skill": re.sub(r"\s+", " ", str(q.get("skill") or "")).strip()[:40],
            "figure": bool(q.get("figure")), "box": q.get("box")}


def crop(path: Path, page: int, box, name: str) -> bool:
    try:
        x0, y0, x1, y1 = (max(0.0, min(1.0, float(v))) for v in box)
    except (TypeError, ValueError):
        return False
    if x1 - x0 < 0.03 or y1 - y0 < 0.03:
        return False
    pg = pymupdf.open(path)[page - 1]
    r = pg.rect
    pad = 0.01
    clip = pymupdf.Rect(r.x0 + (x0 - pad) * r.width, r.y0 + (y0 - pad) * r.height,
                        r.x0 + (x1 + pad) * r.width, r.y0 + (y1 + pad) * r.height) & r
    pix = pg.get_pixmap(dpi=FIGURE_DPI, clip=clip)
    scale = min(1.0, 700 / max(pix.width, 1))
    if scale < 1:
        pix = pg.get_pixmap(dpi=int(FIGURE_DPI * scale), clip=clip)
    (IMAGES / name).write_bytes(pix.tobytes("jpeg", jpg_quality=72))
    return True


def write() -> None:
    IMAGES.mkdir(parents=True, exist_ok=True)
    by_id = {p_id: p for p in pdfs() for p_id in [file_id(p)]}
    banks = {t: {} for t in SECTIONS}
    skipped = {"no-answer-or-invalid": 0, "duplicate": 0, "figure-missing": 0}
    for record_path in sorted(CACHE.glob("*/*.json")):
        record = json.loads(record_path.read_text(encoding="utf-8"))
        src = by_id.get(record_path.parent.name)
        if src is None:
            continue
        for raw in record["questions"]:
            q = clean(raw)
            if q is None:
                skipped["no-answer-or-invalid"] += 1
                continue
            track = TRACK_OF_SECTION[q["section"]]
            key = norm(q["text"]) + "|" + "|".join(sorted(norm(o) for o in q["options"]))
            qid = ("qd-" if track == "qudurat" else "th-") + hashlib.sha1(key.encode("utf-8")).hexdigest()[:10]
            if qid in banks[track]:
                skipped["duplicate"] += 1
                continue
            item = {"id": qid, "section": q["section"], "skill": q["skill"], "text": q["text"],
                    "options": q["options"], "answer": q["answer"], "source": f"{src.stem} ص {record['page']}"}
            if q["figure"]:
                name = qid + ".jpg"
                if not ((IMAGES / name).exists() or crop(src, record["page"], q["box"], name)):
                    skipped["figure-missing"] += 1
                    continue
                item["image"] = name
            banks[track][qid] = item
    for track, items in banks.items():
        path = BANK / f"{track}.json"
        version = 1
        if path.exists():
            old = json.loads(path.read_text(encoding="utf-8"))
            version = int(old.get("version", 0)) + (1 if len(old.get("questions", [])) != len(items) else 0)
        data = {"track": track, "version": version,
                "sections": [{"id": i, "name": n} for i, n in SECTIONS[track]],
                "questions": sorted(items.values(), key=lambda x: x["id"])}
        path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
        per = {s: sum(1 for x in items.values() if x["section"] == s) for s, _ in SECTIONS[track]}
        out(f"{track}: {len(items)} سؤالًا {per}")
    used = {x.get("image") for b in banks.values() for x in b.values()}
    for f in IMAGES.glob("*.jpg"):
        if f.name not in used:
            f.unlink()
    out(f"مُستبعد: {skipped}")


TILE_W = 784       # two pages per row in a 1568-pixel image: the most Claude reads without shrinking
TILE_MAX_H = 1568


def page_key(path: Path, i: int) -> str:
    pix = pymupdf.open(path)[i].get_pixmap(dpi=24, colorspace=pymupdf.csGRAY)
    return hashlib.md5(pix.samples).hexdigest()


def tiles(folder: Path, count: int) -> None:
    """The next unread pages in images of up to 15 slides or 2 portrait pages; a page identical to one already queued or read is skipped."""
    from PIL import Image, ImageDraw
    folder.mkdir(parents=True, exist_ok=True)
    manifest_path = folder / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {"tiles": {}, "seen": {}}
    queued = {tuple(x[:2]) for v in manifest["tiles"].values() for x in v}
    pending = []
    for p in pdfs():
        fid = file_id(p)
        doc = pymupdf.open(p)
        for i in range(len(doc)):
            if (fid, i + 1) in queued or (CACHE / fid / f"{i + 1}.json").exists():
                continue
            key = page_key(p, i)
            if key in manifest["seen"] and manifest["seen"][key] != [fid, i + 1]:
                continue
            manifest["seen"][key] = [fid, i + 1]
            pending.append((p, fid, i))
        if len(pending) >= count * 15:
            break
    n = len(manifest["tiles"])
    made = 0
    while pending and made < count:
        n += 1
        made += 1
        canvas, x, y, row_h, placed = Image.new("RGB", (TILE_W * 2, TILE_MAX_H), "white"), 0, 0, 0, []
        while pending:
            p, fid, i = pending[0]
            pg = pymupdf.open(p)[i]
            cell = TILE_W * 2 // 3   # three pages a row: slides, and portrait pages two rows deep
            pix = pg.get_pixmap(dpi=max(40, int(72 * cell / pg.rect.width)))
            img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
            img = img.resize((cell, max(1, int(img.height * cell / img.width))))
            if img.height > TILE_MAX_H:
                img = img.resize((int(img.width * TILE_MAX_H / img.height), TILE_MAX_H))
            if x + img.width > TILE_W * 2:
                x, y, row_h = 0, y + row_h, 0
            if y + img.height > TILE_MAX_H:
                break
            canvas.paste(img, (x, y))
            draw = ImageDraw.Draw(canvas)
            draw.rectangle([x, y, x + img.width - 1, y + img.height - 1], outline="red", width=3)
            k = len(placed) + 1
            draw.rectangle([x, y, x + 46, y + 40], fill="red")
            draw.text((x + 10, y + 6), str(k), fill="white", font_size=30)
            placed.append([fid, i + 1, str(p.relative_to(SOURCES))])
            x, row_h = x + img.width, max(row_h, img.height)
            pending.pop(0)
        canvas = canvas.crop((0, 0, TILE_W * 2, y + row_h))
        canvas.save(folder / f"t{n:04}.jpg", quality=85)
        manifest["tiles"][f"t{n:04}"] = placed
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    out(f"صور جديدة: {made}، آخرها t{n:04}")


def ingest(folder: Path) -> None:
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    saved = 0
    for path in sorted((folder / "answers").glob("*.json")):
        answers = json.loads(path.read_text(encoding="utf-8"))
        read_tiles = answers.pop("_tiles", [path.stem])
        for key, items in answers.items():
            tile, k = key.rsplit("-", 1)
            fid, page, rel = manifest["tiles"][tile][int(k) - 1]
            if (CACHE / fid / f"{page}.json").exists():
                continue
            questions = []
            for it in items:
                sec, skill, text, options, ans, box = it
                questions.append({"text": text, "options": options, "answer": "أبجد"[ans],
                                  "section": {"v": "verbal", "q": "quant", "m": "math", "p": "physics",
                                              "c": "chemistry", "b": "biology"}.get(sec, sec), "skill": skill,
                                  "figure": box is not None, "box": box})
            (CACHE / fid).mkdir(parents=True, exist_ok=True)
            (CACHE / fid / f"{page}.json").write_text(json.dumps(
                {"file": rel, "page": page, "questions": questions, "provider": "claude-code", "model": "subscription"},
                ensure_ascii=False), encoding="utf-8")
            saved += 1
        # every page of a read tile without an entry had no questions
        for k, (fid, page, rel) in enumerate(p for tile in read_tiles for p in manifest["tiles"].get(tile, [])):
            if not (CACHE / fid / f"{page}.json").exists():
                (CACHE / fid).mkdir(parents=True, exist_ok=True)
                (CACHE / fid / f"{page}.json").write_text(json.dumps(
                    {"file": rel, "page": page, "questions": [], "provider": "claude-code", "model": "subscription"},
                    ensure_ascii=False), encoding="utf-8")
                saved += 1
    total = sum(1 for _ in CACHE.glob("*/*.json"))
    out(f"حُفظت {saved} صفحة، والمقروء كله {total}")


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    global ONLY
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if "--only" in sys.argv:
        ONLY = sys.argv[sys.argv.index("--only") + 1]
    if cmd == "scan":
        scan()
    elif cmd == "read":
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
        read(limit)
    elif cmd == "tiles":
        count = int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 10
        tiles(Path(sys.argv[2]), count)
    elif cmd == "ingest":
        ingest(Path(sys.argv[2]))
    elif cmd == "write":
        write()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
