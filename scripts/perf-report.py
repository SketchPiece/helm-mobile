#!/usr/bin/env python3
"""Reads a performance recording from the app (Settings → Performance) and says where the time went.

    scripts/perf-report.py --pull                 # copy Documents/Performance off a connected iPad/iPhone, read the newest
    scripts/perf-report.py build/perf/perf-….json # read one recording
    scripts/perf-report.py --keep-dsym            # after a deploy: keep this build's dSYM for later recordings

The app's own frames in stall stacks are offsets into a stripped binary; they are named with
atos against the dSYM whose UUID the recording carries (kept under build/dsyms, the last
Sideshelf archive, the Release build products, or anywhere Spotlight finds it).
"""
import argparse
import collections
import glob
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE_ID = "com.sketchpiece.helm"
PULLED = os.path.join(ROOT, "build", "perf")
DSYMS = os.path.join(ROOT, "build", "dsyms")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def dsym_uuids(path):
    out = run(["dwarfdump", "--uuid", path]).stdout
    return {line.split()[1] for line in out.splitlines() if line.startswith("UUID:")}


def candidate_dsyms():
    patterns = [
        os.path.join(DSYMS, "*", "*.dSYM"),
        os.path.join(ROOT, "build", "ota-deploy", "App.xcarchive", "dSYMs", "HelmMobile.app.dSYM"),
        os.path.join(ROOT, "build", "*", "Build", "Products", "Release-iphone*", "HelmMobile.app.dSYM"),
    ]
    for pattern in patterns:
        yield from glob.glob(pattern)


def find_dsym(uuid):
    for path in candidate_dsyms():
        if uuid in dsym_uuids(path):
            return path
    found = run(["mdfind", f"com_apple_xcode_dsym_uuids == {uuid}"]).stdout.split()
    return found[0] if found else None


def keep_dsym():
    for path in candidate_dsyms():
        if path.startswith(DSYMS):
            continue
        for uuid in dsym_uuids(path):
            target = os.path.join(DSYMS, uuid, os.path.basename(path))
            if not os.path.exists(target):
                shutil.copytree(path, target)
                print(f"kept {target}")


def pull():
    devices = json.loads(run_json(["xcrun", "devicectl", "list", "devices"]))
    connected = [d for d in devices["result"]["devices"]
                 if d.get("connectionProperties", {}).get("tunnelState") != "unavailable"
                 and d.get("hardwareProperties", {}).get("platform") == "iOS"
                 and d.get("hardwareProperties", {}).get("reality") == "physical"]
    if not connected:
        sys.exit("no connected iPhone or iPad (devicectl list devices)")
    # An iPad first: that's where the stutter is being chased.
    connected.sort(key=lambda d: d["hardwareProperties"].get("deviceType") != "iPad")
    device = connected[0]
    print(f"pulling from {device['deviceProperties']['name']}")
    os.makedirs(PULLED, exist_ok=True)
    result = run(["xcrun", "devicectl", "device", "copy", "from", "--device", device["identifier"],
                  "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
                  "--source", "Documents/Performance", "--destination", PULLED])
    if result.returncode != 0:
        sys.exit(result.stderr or result.stdout)
    recordings = sorted(glob.glob(os.path.join(PULLED, "**", "perf-*.json"), recursive=True))
    if not recordings:
        sys.exit("no recordings on the device yet")
    return recordings[-1]


def run_json(cmd):
    path = os.path.join(PULLED, ".devicectl.json")
    os.makedirs(PULLED, exist_ok=True)
    run(cmd + ["--json-output", path])
    with open(path) as f:
        return f.read()


def demangle(names):
    if not names:
        return {}
    out = run(["xcrun", "swift-demangle", "--simplified", "--compact"], input="\n".join(names)).stdout.splitlines()
    return dict(zip(names, out)) if len(out) == len(names) else {n: n for n in names}


def symbolicate(report):
    """address (int) → readable frame name, the app's own frames through atos."""
    symbols = report["symbols"]
    app_image = next((i for i in report["images"] if i.get("uuid") == report.get("appUUID")), None)
    names = {}
    app_addresses = []
    for key, frame in symbols.items():
        address = int(key, 16)
        if app_image and frame["image"] == app_image["name"]:
            app_addresses.append(address)
        names[address] = f"{frame['image']}  {frame.get('symbol') or hex(frame['offset'])}"
    if app_addresses and report.get("appUUID"):
        dsym = find_dsym(report["appUUID"])
        if not dsym:
            print(f"! no dSYM for {report['appUUID']}; app frames stay as offsets", file=sys.stderr)
        else:
            binary = glob.glob(os.path.join(dsym, "Contents", "Resources", "DWARF", "*"))[0]
            # Return addresses point after the call; one byte back lands on the call's line.
            queries = [hex(a - 1) for a in app_addresses]
            out = run(["atos", "-o", binary, "-arch", "arm64", "-l", hex(app_image["base"])] + queries).stdout.splitlines()
            for address, line in zip(app_addresses, out):
                names[address] = "Helm  " + line
    mangled = sorted({n.split("  ", 1)[1] for n in names.values() if "  $s" in n or "  _$s" in n})
    readable = demangle(mangled)
    for address, name in names.items():
        image, _, symbol = name.partition("  ")
        if symbol in readable:
            names[address] = f"{image}  {readable[symbol]}"
    return names


def is_app(name):
    return name.startswith("Helm  ")


def short(name, width=150):
    return name if len(name) <= width else name[: width - 1] + "…"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", nargs="?")
    parser.add_argument("--pull", action="store_true")
    parser.add_argument("--keep-dsym", action="store_true")
    parser.add_argument("--top", type=int, default=25)
    args = parser.parse_args()

    if args.keep_dsym:
        keep_dsym()
        if not args.report and not args.pull:
            return
    path = pull() if args.pull else args.report
    if not path:
        parser.error("give a recording or --pull")
    with open(path) as f:
        report = json.load(f)
    names = symbolicate(report)
    top = args.top

    print(f"# {os.path.basename(path)}")
    print(report["device"])
    seconds = report["seconds"] or 1
    print(f"{seconds:.0f} s, {report['frames']} frames ({report['frames'] / seconds:.0f} fps), "
          f"{report['hitches']} hitches, {report['hitchMs']:.0f} ms late ({report['hitchMs'] / seconds:.1f} ms/s)")
    if report["scrollSeconds"]:
        print(f"scrolling {report['scrollSeconds']:.1f} s: {report['scrollHitchMs']:.0f} ms late "
              f"({report['scrollHitchMs'] / report['scrollSeconds']:.1f} ms/s)")

    events = report["events"]
    hitches = [e for e in events if e["kind"] == "hitch"]
    by_context = collections.defaultdict(lambda: [0, 0.0])
    work_in_hitches = collections.defaultdict(lambda: [0, 0.0])
    for hitch in hitches:
        entry = by_context[hitch.get("context") or "?"]
        entry[0] += 1
        entry[1] += hitch["ms"]
        for work in hitch.get("work") or []:
            w = work_in_hitches[work["name"]]
            w[0] += work["count"]
            w[1] += work["ms"]
    if by_context:
        print("\n## Hitches by where they happened (count, ms late)")
        for context, (count, ms) in sorted(by_context.items(), key=lambda kv: -kv[1][1])[:top]:
            print(f"{count:6d} {ms:9.0f} ms  {context}")
    if work_in_hitches:
        print("\n## Main-thread work inside late frames (count, ms)")
        for name, (count, ms) in sorted(work_in_hitches.items(), key=lambda kv: -kv[1][1])[:top]:
            print(f"{count:6d} {ms:9.1f} ms  {name}")

    stalls = report["stalls"]
    samples = [s for stall in stalls for s in stall["samples"]]
    if samples:
        print(f"\n## Stalls: {len(stalls)}, {sum(s['ms'] for s in stalls):.0f} ms, {len(samples)} stack samples")
        for stall in sorted(stalls, key=lambda s: -s["ms"])[:10]:
            print(f"  +{stall['t']:8.2f}s {stall['ms']:6.0f} ms  {stall.get('context') or ''}")

        inclusive = collections.Counter()
        leaf = collections.Counter()
        innermost_app = collections.Counter()
        for sample in samples:
            frames = [names.get(a, hex(a)) for a in sample]
            leaf[frames[0]] += 1
            for name in set(frames):
                inclusive[name] += 1
            app = next((f for f in frames if is_app(f)), None)
            if app:
                innermost_app[app] += 1
        total = len(samples)

        def table(title, counter, only_app=False):
            print(f"\n## {title}")
            rows = [(n, c) for n, c in counter.most_common() if not only_app or is_app(n)][:top]
            for name, count in rows:
                print(f"{100 * count / total:5.1f}%  {short(name)}")

        table("Innermost Helm frame per sample (what our code was doing)", innermost_app)
        table("Helm frames on the stack (inclusive)", inclusive, only_app=True)
        table("Leaf frames (where the CPU actually was)", leaf)
        base = collections.Counter({n: c for n, c in inclusive.items() if c < 0.9 * total})
        table("All frames on the stack (inclusive, without the run loop under everything)", base)

    stats = [s for s in report["stats"] if s["mainCount"]]
    if stats:
        print("\n## Main-thread work, whole recording (count, total, max, units)")
        for s in stats[:top]:
            print(f"{s['mainCount']:7d} {s['mainMs']:9.1f} ms {s['maxMs']:7.1f} ms  {s['units'] or '':>9}  {s['name']}")
    background = [s for s in report["stats"] if s["count"] > s["mainCount"]]
    if background:
        print("\n## Off the main thread")
        for s in sorted(background, key=lambda s: -(s["totalMs"] - s["mainMs"]))[:top]:
            print(f"{s['count'] - s['mainCount']:7d} {s['totalMs'] - s['mainMs']:9.1f} ms  {s['units'] or '':>9}  {s['name']}")

    marks = [e for e in events if e["kind"] in ("mark", "scroll")]
    if marks:
        print("\n## Timeline")
        for e in marks:
            print(f"  +{e['t']:8.2f}s  {e['name']} {e.get('detail') or ''}")


if __name__ == "__main__":
    main()
