"""Keep Zig 0.14's libSystem compatibility workaround inside .build only.

New Apple SDKs advertise arm64e without arm64 in libSystem's linker stub, which
Zig 0.14 cannot resolve. Use Zig's own bundled stub with the real SDK's headers
and frameworks. This changes neither the installed SDK nor the Zig installation.
Print a build-only tool directory to prepend to PATH, or nothing if unnecessary.
"""

import json
import os
from pathlib import Path
import platform
import shlex
import subprocess


def link(destination: Path, source: Path) -> None:
    if destination.is_symlink():
        if os.readlink(destination) == str(source):
            return
        destination.unlink()
    elif destination.exists():
        raise RuntimeError(f"Refusing to replace a non-symlink: {destination}")
    destination.symlink_to(source)


def main() -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        return
    sdk = Path(subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip())
    # The file embeds reexported libraries too. Only libSystem's first target
    # declaration determines whether Zig can select the umbrella library.
    declaration = (sdk / "usr/lib/libSystem.tbd").read_text().split("install-name:", 1)[0]
    if "arm64-macos" in declaration:
        return
    zig = json.loads(subprocess.check_output(["zig", "env"], text=True))
    stub = Path(zig["lib_dir"]) / "libc/darwin/libSystem.tbd"
    if not stub.is_file():
        raise RuntimeError("Zig's bundled libSystem stub is unavailable")
    root = Path(__file__).resolve().parent.parent / ".build/ghostty"
    overlay = root / "sdk-overlay"
    (overlay / "usr/lib").mkdir(parents=True, exist_ok=True)
    for child in sdk.iterdir():
        if child.name != "usr":
            link(overlay / child.name, child)
    for child in (sdk / "usr").iterdir():
        if child.name != "lib":
            link(overlay / "usr" / child.name, child)
    for child in (sdk / "usr/lib").iterdir():
        link(overlay / "usr/lib" / child.name,
             stub if child.name == "libSystem.tbd" else child)
    shims = root / "tool-shims"
    shims.mkdir(exist_ok=True)
    shim = shims / "xcrun"
    shim.write_text(
        '#!/bin/bash\n'
        'if [[ "$#" == 3 && "$1" == --sdk && "$2" == macosx && "$3" == --show-sdk-path ]]; then\n'
        f'    printf "%s\\n" {shlex.quote(str(overlay))}\n'
        'else\n'
        '    exec /usr/bin/xcrun "$@"\n'
        'fi\n'
    )
    shim.chmod(0o755)
    print(shims)


if __name__ == "__main__":
    main()
