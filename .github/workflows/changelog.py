#!/usr/bin/env python3
"""Generate a GitHub Release changelog by diffing the RPM package sets of the
published Monolith images.

The workflow extracts `rpm -qa` from the previous and current build of every
edition into `<edition>.prev.txt` / `<edition>.curr.txt` (one
`name<TAB>epoch:version-release` per line) inside a packages dir, and passes
that here. This script produces a Markdown changelog plus an env file with the
release title and tag, mirroring how Bazzite publishes its per-build notes.

Each base (non-NVIDIA) edition gets its own package-diff section. Its NVIDIA
variant, if present, gets a sub-section listing only the packages it adds over
the base (the driver stack) that changed -- so a driver bump surfaces an NVIDIA
section, and a build with no driver change shows none.
"""

import argparse
import os
import re
import subprocess

# Packages surfaced in the "Major packages" table of each base edition's section,
# as (display name, rpm name). Rows whose package is absent are skipped, so an
# edition only shows the ones it actually ships.
MAJOR_PACKAGES = [
    ("Kernel", "kernel"),
    ("Mesa", "mesa-dri-drivers"),
    ("GNOME Shell", "gnome-shell"),
    ("Mutter", "mutter"),
    ("systemd", "systemd"),
    ("Brave", "brave-origin-nightly"),
    ("Steam", "steam"),
    ("Gamescope", "gamescope"),
    ("GameMode", "gamemode"),
    ("MangoHud", "mangohud"),
    ("Mesa Vulkan", "mesa-vulkan-drivers"),
    ("Tailscale", "tailscale"),
    ("Fish", "fish"),
]

EPOCH_PATTERN = re.compile(r"^(?:\d+|\(none\)):")
FEDORA_PATTERN = re.compile(r"\.fc\d+")


def clean_version(version: str) -> str:
    """Drop the leading epoch and the trailing `.fcNN` dist tag for readability."""
    version = EPOCH_PATTERN.sub("", version)
    version = FEDORA_PATTERN.sub("", version)
    return version


def parse_packages(path: str) -> dict[str, str]:
    """Read a `name<TAB>EVR` package list into a cleaned {name: version} dict.

    Multilib packages appear once per arch with the same version; we keep the
    last (identical) entry, which collapses the duplicates.
    """
    packages: dict[str, str] = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            name, version = line.split("\t", 1)
            packages[name] = clean_version(version)
    return packages


def major_table(prev: dict[str, str], curr: dict[str, str]) -> str:
    rows = ""
    for display, pkg in MAJOR_PACKAGES:
        if pkg not in curr:
            continue
        new = curr[pkg]
        old = prev.get(pkg)
        if old and old != new:
            value = f"{old} ➡️ {new}"
        else:
            value = new
        rows += f"\n| **{display}** | {value} |"
    if not rows:
        return ""
    return "### Major packages\n| Name | Version |\n| --- | --- |" + rows + "\n\n"


def changes_table(prev: dict[str, str], curr: dict[str, str]) -> str:
    added = sorted(set(curr) - set(prev))
    removed = sorted(set(prev) - set(curr))
    changed = sorted(p for p in set(prev) & set(curr) if prev[p] != curr[p])

    if not (added or removed or changed):
        return "_No package changes._\n\n"

    out = "### Package changes\n| | Name | Previous | New |\n| --- | --- | --- | --- |"
    for p in changed:
        out += f"\n| 🔄 | {p} | {prev[p]} | {curr[p]} |"
    for p in added:
        out += f"\n| ✨ | {p} | | {curr[p]} |"
    for p in removed:
        out += f"\n| ❌ | {p} | {prev[p]} | |"
    return out + "\n\n"


def nvidia_delta_table(
    prev_base: dict[str, str],
    curr_base: dict[str, str],
    prev_nv: dict[str, str],
    curr_nv: dict[str, str],
    edition: str,
) -> str:
    """Diff only the packages the NVIDIA image adds over its base (the driver
    stack). Returns "" when that delta is unchanged, so the section appears only
    when the driver actually moves."""
    prev_delta = {p: v for p, v in prev_nv.items() if p not in prev_base}
    curr_delta = {p: v for p, v in curr_nv.items() if p not in curr_base}

    added = sorted(set(curr_delta) - set(prev_delta))
    removed = sorted(set(prev_delta) - set(curr_delta))
    changed = sorted(p for p in set(prev_delta) & set(curr_delta) if prev_delta[p] != curr_delta[p])
    if not (added or removed or changed):
        return ""

    out = (
        f"### NVIDIA driver changes (`{edition}`)\n"
        "| | Name | Previous | New |\n| --- | --- | --- | --- |"
    )
    for p in changed:
        out += f"\n| 🔄 | {p} | {prev_delta[p]} | {curr_delta[p]} |"
    for p in added:
        out += f"\n| ✨ | {p} | | {curr_delta[p]} |"
    for p in removed:
        out += f"\n| ❌ | {p} | {prev_delta[p]} | |"
    return out + "\n\n"


def commits_section(workdir: str, prev_rev: str, curr_rev: str, repo: str) -> str:
    try:
        if not prev_rev:
            return ""
        # Both revisions must resolve in this checkout.
        for rev in (prev_rev, curr_rev):
            subprocess.run(
                ["git", "-C", workdir, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        log = subprocess.run(
            ["git", "-C", workdir, "log", "--no-merges",
             "--pretty=format:%H\x1f%h\x1f%an\x1f%s", f"{prev_rev}..{curr_rev}"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8")
    except subprocess.CalledProcessError:
        return ""

    rows = ""
    for line in log.split("\n"):
        if not line:
            continue
        full, short, author, subject = line.split("\x1f")
        rows += f"\n| [`{short}`](https://github.com/{repo}/commit/{full}) | {subject} | {author} |"
    if not rows:
        return ""
    return "### Commits\n| Hash | Subject | Author |\n| --- | --- | --- |" + rows + "\n\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packages-dir", required=True, help="dir holding <edition>.prev.txt / <edition>.curr.txt")
    parser.add_argument("--images", required=True, help="comma-separated full image refs, one per edition, non-NVIDIA first")
    parser.add_argument("--prev-tag", required=True, help="previous image tag, e.g. 20260614")
    parser.add_argument("--curr-tag", required=True, help="current image tag, e.g. 20260615")
    parser.add_argument("--prev-release-tag", default="", help="previous release/git tag, e.g. 2026-06-14 (defaults to --prev-tag)")
    parser.add_argument("--curr-release-tag", default="", help="current release/git tag, e.g. 2026-06-15 (defaults to --curr-tag)")
    parser.add_argument("--repo", required=True, help="owner/name for commit links")
    parser.add_argument("--workdir", default=".")
    parser.add_argument("--prev-rev", default="", help="git ref of the previous release (for commit range)")
    parser.add_argument("--curr-rev", default="HEAD")
    parser.add_argument("--handwritten", default="")
    parser.add_argument("--output", required=True, help="env file for title/tag")
    parser.add_argument("--changelog", required=True, help="markdown output path")
    args = parser.parse_args()

    images = [i.strip() for i in args.images.split(",") if i.strip()]
    editions = [img.rsplit("/", 1)[-1] for img in images]
    ref_by_name = dict(zip(editions, images))

    # Load each edition's package sets. A missing curr file means the edition
    # isn't in this build; a missing prev file (brand-new edition) means
    # everything it ships shows as added.
    prev: dict[str, dict[str, str]] = {}
    curr: dict[str, dict[str, str]] = {}
    for name in editions:
        curr_path = os.path.join(args.packages_dir, f"{name}.curr.txt")
        if not os.path.exists(curr_path):
            continue
        curr[name] = parse_packages(curr_path)
        prev_path = os.path.join(args.packages_dir, f"{name}.prev.txt")
        prev[name] = parse_packages(prev_path) if os.path.exists(prev_path) else {}

    present = [n for n in editions if n in curr]

    prev_release = args.prev_release_tag or args.prev_tag
    curr_release = args.curr_release_tag or args.curr_tag

    title = curr_release
    body = ""
    if args.handwritten:
        body += args.handwritten + "\n\n"
    body += (
        f"Changes from the previous build [`{prev_release}`]"
        f"(https://github.com/{args.repo}/releases/tag/{prev_release}) "
        f"to [`{curr_release}`](https://github.com/{args.repo}/releases/tag/{curr_release}).\n\n"
    )
    if present:
        names = ", ".join(f"`{e}`" for e in present)
        body += f"Editions in this build: {names}.\n\n"

    # One section per base (non-NVIDIA) edition, with its NVIDIA variant folded in
    # as a driver-delta sub-section.
    handled: set[str] = set()
    for base in (n for n in present if not n.endswith("-nvidia")):
        handled.add(base)
        body += f"## `{base}`\n\n"
        body += major_table(prev.get(base, {}), curr[base])
        body += changes_table(prev.get(base, {}), curr[base])
        nv = f"{base}-nvidia"
        if nv in curr:
            handled.add(nv)
            body += nvidia_delta_table(prev.get(base, {}), curr[base], prev.get(nv, {}), curr[nv], nv)

    # Any edition without a recognized base (e.g. a standalone NVIDIA image) still
    # gets a full section so nothing is silently dropped.
    for name in present:
        if name in handled:
            continue
        body += f"## `{name}`\n\n"
        body += major_table(prev.get(name, {}), curr[name])
        body += changes_table(prev.get(name, {}), curr[name])

    body += commits_section(args.workdir, args.prev_rev, args.curr_rev, args.repo)

    body += "### How to rebase\nPick your edition. Rebase to this exact build, or track the latest:\n\n"
    for name in present:
        img = ref_by_name[name]
        body += (
            f"**`{name}`**\n\n"
            "```bash\n"
            "# this exact build\n"
            f"rpm-ostree rebase ostree-image-signed:docker://{img}:{args.curr_tag}\n"
            "# or track the latest build\n"
            f"rpm-ostree rebase ostree-image-signed:docker://{img}:latest\n"
            "```\n\n"
        )

    with open(args.changelog, "w") as f:
        f.write(body)
    with open(args.output, "w") as f:
        f.write(f"TITLE={title}\nTAG={curr_release}\n")

    print(f"Title: {title}")
    print(body)


if __name__ == "__main__":
    main()
