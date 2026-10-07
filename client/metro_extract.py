#!/usr/bin/env python3
"""Metro (React Native) bundle module extractor.

Splits an index.jsbundle / index.android.bundle into modules using the
canonical Metro record shape:

    __d(function(g,r,i,a,m,e,d){ ...body... },<id>,[<dep>,<dep>,...]<,"name">);

Usage:
    python client/metro_extract.py <bundle> --id 605
    python client/metro_extract.py <bundle> --grep signKey
    python client/metro_extract.py <bundle> --chain 605
"""
from __future__ import annotations

import argparse
import json
import re
import sys

D_MOD = "__d(function("
# module record tail: },<id>,[<deps>]  (optionally ,"name" before the final );)
RE_TAIL = re.compile(r"\},(\d+),\[([0-9,\s]*)\]")


class Bundle:
    def __init__(self, path: str):
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            self.text = f.read()
        self.modules: dict[int, dict] = {}
        self._parse()

    def _parse(self) -> None:
        s = self.text
        # every module body begins with the literal prefix
        starts = []
        i = s.find(D_MOD)
        while i != -1:
            starts.append(i)
            i = s.find(D_MOD, i + 1)
        # pair each start with the *first* tail marker after it that has no
        # other start in between (that would mean a nested module record)
        for idx, st in enumerate(starts):
            nxt = starts[idx + 1] if idx + 1 < len(starts) else len(s)
            m = RE_TAIL.search(s, st, nxt)
            if not m:
                continue
            mid = int(m.group(1))
            deps = [int(x) for x in m.group(2).split(",") if x.strip()]
            body_start = st + len(D_MOD)
            body = s[body_start : m.start()]
            self.modules[mid] = {"id": mid, "deps": deps, "body": body}

    def get(self, mid: int) -> dict | None:
        return self.modules.get(mid)

    def grep(self, needle: str):
        out = []
        for mid, mod in self.modules.items():
            if needle in mod["body"]:
                out.append(mid)
        return sorted(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--id", type=int)
    ap.add_argument("--grep")
    ap.add_argument("--chain", type=int, help="follow re-export chain from this id")
    ap.add_argument("--deps", action="store_true", help="show deps for --id")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--maxlen", type=int, default=4000)
    args = ap.parse_args()

    b = Bundle(args.bundle)
    print(f"[*] modules parsed: {len(b.modules)}", file=sys.stderr)

    if args.grep:
        hits = b.grep(args.grep)
        print(f"[grep] '{args.grep}' -> {len(hits)} modules")
        for mid in hits:
            print(f"  module {mid}  deps={b.modules[mid]['deps']}")
        return 0

    if args.chain is not None:
        cur = args.chain
        seen = set()
        while cur is not None and cur not in seen:
            seen.add(cur)
            mod = b.get(cur)
            if mod is None:
                print(f"module {cur} NOT FOUND")
                break
            # detect pure re-export: body only has Object.defineProperty(...get...r(d[K])...)
            getters = re.findall(r"return r\(d\[(\d+)\]\)\.([A-Za-z_$][\w$]*)", mod["body"])
            print(f"module {cur}  deps={mod['deps']}  getters={getters[:12]}")
            nxt = None
            if getters:
                # follow the dependency that provides getRequestInfo
                for k, name in getters:
                    if name in ("getRequestInfo", "TokenErrorCode"):
                        nxt = mod["deps"][int(k)]
                        break
                if nxt is None:
                    nxt = mod["deps"][int(getters[0][0])]
            if nxt is None:
                print(f"  -> leaf module {cur}")
                print("  body:", mod["body"][: args.maxlen])
                break
            cur = nxt
        return 0

    if args.id is not None:
        mod = b.get(args.id)
        if mod is None:
            print(f"module {args.id} NOT FOUND")
            return 1
        if args.json:
            print(json.dumps(mod))
        else:
            print(f"=== module {args.id} ===")
            print(f"deps: {mod['deps']}")
            print(mod["body"][: args.maxlen])
        return 0

    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
