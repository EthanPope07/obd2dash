from pathlib import Path

root = Path(__file__).resolve().parents[1]
markers = ("\u00c2", "\u00c3", "\u00e2\u20ac", "\ufffd")
failures = []
for path in root.rglob("*.swift"):
    if ".build" in path.parts:
        continue
    source = path.read_text(encoding="utf-8")
    if any(marker in source for marker in markers):
        failures.append(str(path.relative_to(root)))
if failures:
    raise SystemExit("Possible corrupted text: " + ", ".join(failures))
print("Swift source text encoding checked")
