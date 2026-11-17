"""Check the packaged executable, not just the source layout, for smoke code."""
from pathlib import Path
import re

app = Path("dist/Discobox.app")
executable = app / "Contents/MacOS/DiscoboxDesktop"
data = executable.read_bytes()
for source in Path("Sources/DiscoboxSmoke").glob("*Smoke.swift"):
    assert source.stem.encode() not in data, f"Smoke runner leaked into release: {source.stem}"
flags = set(re.findall(rb"--[a-z-]+-smoke", Path("Sources/DiscoboxSmoke/SmokeApp.swift").read_bytes()))
assert flags, "Smoke launcher no longer declares its fixture flags"
for marker in flags | {b"DiscoboxSmoke"}:
    assert marker not in data, f"Smoke entry point leaked into release: {marker!r}"
assert not any("Smoke" in path.name for path in app.rglob("*")), "Smoke artifacts packaged in release"
print("Release contains no smoke runners or smoke launch flags")
