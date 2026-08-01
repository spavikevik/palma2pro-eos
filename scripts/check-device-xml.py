#!/usr/bin/env python3
"""Validate every XML file in the device tree before shipping it to the builder.

WHY THIS EXISTS
---------------
aapt2 rejects a malformed resource file with only:

    config.xml:0: error: xml parser error: not well-formed (invalid token).

No line, no column, no cause. The usual cause here has been a literal double
hyphen inside an XML comment, which is illegal in XML and easy to type in prose
("costs nothing -- only live wallpapers do"). That mistake cost two full build
cycles on this project, roughly 45 minutes each, because a device-tree change
also forces a kati regeneration before anything compiles.

Running this first turns a 45 minute round trip into a second.

    scripts/check-device-xml.py [root]
"""

import pathlib
import re
import sys
import xml.dom.minidom


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "device")
    bad = 0
    checked = 0
    for path in sorted(root.rglob("*.xml")):
        checked += 1
        text = path.read_text(errors="replace")
        # Report the specific cause before the generic parse error, since the
        # parse error alone does not say which construct is at fault.
        for m in re.finditer(r"<!--(.*?)-->", text, flags=re.S):
            if re.search(r"(?<!<!)--(?!>)", m.group(1)):
                line = text[: m.start()].count("\n") + 1
                print(f"  FAIL {path}:{line}: '--' inside an XML comment")
                bad += 1
                break
        else:
            try:
                xml.dom.minidom.parse(str(path))
            except Exception as exc:  # noqa: BLE001 -- report whatever it says
                print(f"  FAIL {path}: {exc}")
                bad += 1
                continue
            print(f"  ok   {path}")
    print(f"\n{checked} file(s), {bad} bad")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
