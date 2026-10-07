#!/usr/bin/env python3
"""Regenerate VoiceInk's custom symbols with SwiftDraw 0.29.0."""

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PHOSPHOR_VERSION = "2.1.1"
PHOSPHOR_SHA512 = "v4ARvrip4qBCImOE5rmPUylOEK4iiED9ZyKjcvzuezqMaiRASCHKcRIuvvxL/twvLpkfnEODCOJp5dM4eZilxQ=="
SVG_NAMESPACE = "http://www.w3.org/2000/svg"

# Phosphor name, weight, SF Symbol aliases, optional sidebar tint.
SYMBOLS = [
    ("gauge", "regular", ["gauge.medium"], True),
    ("house", "regular", ["house"], False),
    ("stack", "regular", ["square.stack", "sparkles.square.fill.on.square"], True),
    ("waveform", "regular", ["waveform", "waveform.path"], True),
    ("clock", "regular", ["clock"], True),
    ("book-open-text", "regular", ["text.book.closed", "character.book.closed"], True),
    ("cpu", "regular", ["cpu"], True),
    ("microphone", "regular", ["mic"], True),
    ("gear-six", "regular", ["gearshape"], True),
    ("seal-check", "regular", ["checkmark.seal"], True),
    ("microphone", "fill", ["mic.fill"], False),
    ("gear-six", "fill", ["gearshape.fill"], False),
    ("seal-check", "fill", ["checkmark.seal.fill"], False),
    ("file-text", "fill", ["doc.text.fill"], False),
    ("book-open-text", "fill", ["text.book.closed.fill", "character.book.closed.fill"], False),
    ("x", "regular", ["xmark"], False),
    ("globe", "regular", ["globe"], False),
    ("sparkle", "regular", ["sparkles"], False),
    ("check", "regular", ["checkmark"], False),
    ("check-circle", "regular", ["checkmark.circle"], False),
    ("check-circle", "fill", ["checkmark.circle.fill"], False),
    ("x-circle", "regular", ["xmark.circle"], False),
    ("x-circle", "fill", ["xmark.circle.fill"], False),
    ("warning", "regular", ["exclamationmark.triangle"], False),
    ("warning", "fill", ["exclamationmark.triangle.fill"], False),
    ("info", "regular", ["info.circle"], False),
    ("arrow-right", "regular", ["arrow.right"], False),
    ("arrow-up-right", "regular", ["arrow.up.right"], False),
    ("arrow-clockwise", "regular", ["arrow.clockwise"], False),
    ("arrow-counter-clockwise", "regular", ["arrow.counterclockwise"], False),
    ("trash", "regular", ["trash"], False),
    ("folder", "regular", ["folder"], False),
    ("dots-three-circle", "regular", ["ellipsis.circle"], False),
    ("plus-circle", "regular", ["plus.circle"], False),
    ("plus-circle", "fill", ["plus.circle.fill"], False),
    ("pencil-simple", "regular", ["pencil"], False),
    ("pencil-circle", "fill", ["pencil.circle.fill"], False),
    ("note-pencil", "regular", ["square.and.pencil"], False),
    ("caret-right", "regular", ["chevron.right"], False),
    ("caret-left", "regular", ["chevron.left"], False),
    ("caret-down", "regular", ["chevron.down"], False),
    ("caret-up", "regular", ["chevron.up"], False),
    ("caret-up-down", "regular", ["chevron.up.chevron.down"], False),
    ("magnifying-glass", "regular", ["magnifyingglass"], False),
    ("hard-drive", "regular", ["internaldrive"], False),
    ("chart-bar", "regular", ["chart.bar.xaxis", "chart.bar"], False),
    ("magic-wand", "regular", ["wand.and.stars"], False),
    ("squares-four", "regular", ["square.grid.2x2"], False),
    ("play", "fill", ["play.fill"], False),
    ("copy", "regular", ["doc.on.doc"], False),
]


def fetch_sources(work):
    url = f"https://registry.npmjs.org/@phosphor-icons/core/-/core-{PHOSPHOR_VERSION}.tgz"
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read()
    digest = base64.b64encode(hashlib.sha512(data).digest()).decode()
    if digest != PHOSPHOR_SHA512:
        raise ValueError("Phosphor archive checksum does not match the pinned release")
    archive = work / "phosphor.tgz"
    archive.write_bytes(data)
    paths = {"LICENSE"}
    for name, weight, _, has_tint in SYMBOLS:
        suffix = "" if weight == "regular" else f"-{weight}"
        paths.add(f"assets/{weight}/{name}{suffix}.svg")
        if has_tint:
            paths.add(f"assets/duotone/{name}-duotone.svg")
    source = work / "source/package"
    with tarfile.open(archive) as package:
        for path in sorted(paths):
            member = package.extractfile(f"package/{path}")
            if member is None:
                raise ValueError(f"Phosphor source is not a file: {path}")
            destination = source / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            with member:
                destination.write_bytes(member.read())
    return source


def convert(tool, source, insets=None):
    command = [str(tool), str(source), "--format", "sfsymbol"]
    if insets is not None:
        command += ["--insets", insets]
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
    alignment = re.search(r"Alignment: --insets (\S+)", result.stdout)
    if alignment is None:
        raise ValueError(f"SwiftDraw did not report alignment for {source.name}")
    output = source.with_name(source.stem + "-symbol.svg")
    ET.parse(output)
    return output, alignment.group(1)


def write_symbol(catalog, name, source):
    folder = catalog / f"{name}.symbolset"
    folder.mkdir()
    shutil.copyfile(source, folder / f"{name}.svg")
    metadata = {
        "info": {"author": "xcode", "version": 1},
        "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}],
    }
    (folder / "Contents.json").write_text(json.dumps(metadata, indent=2) + "\n")


def extract_tint(source, destination):
    root = ET.parse(source).getroot()
    tint = ET.Element(root.tag, root.attrib)
    for shape in root:
        if shape.get("opacity") == "0.2":
            layer = copy.deepcopy(shape)
            del layer.attrib["opacity"]
            tint.append(layer)
    if not len(tint):
        raise ValueError(f"No duotone tint found in {source.name}")
    ET.register_namespace("", SVG_NAMESPACE)
    ET.ElementTree(tint).write(destination, encoding="utf-8", xml_declaration=True)


def swift_catalog(symbols, tints):
    lines = ["// Generated by scripts/phosphor-symbols.py. Do not edit.", "", "enum AppSymbolCatalog {"]
    for name, entries in [("symbols", symbols), ("tints", tints)]:
        lines.append(f"    static let {name}: [String: String] = [")
        lines.extend(f'        "{key}": "{value}",' for key, value in sorted(entries.items()))
        lines += ["    ]", ""]
    return "\n".join(lines).rstrip() + "\n}\n"


def publish(outputs, work):
    backups = []
    installed = []
    try:
        for index, (source, destination) in enumerate(outputs):
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                backup = work / f"previous-{index}"
                os.replace(destination, backup)
                backups.append((backup, destination))
            os.replace(source, destination)
            installed.append(destination)
    except OSError:
        for destination in reversed(installed):
            if destination.is_dir():
                shutil.rmtree(destination)
            else:
                destination.unlink()
        for backup, destination in reversed(backups):
            os.replace(backup, destination)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("swiftdraw", type=Path, help="Path to SwiftDraw 0.29.0's swiftdrawcli")
    args = parser.parse_args()
    tool = args.swiftdraw.resolve()
    if not tool.is_file() or not os.access(tool, os.X_OK):
        parser.error(f"SwiftDraw executable is unavailable: {tool}")

    scratch = ROOT / ".tmp/phosphor-symbols"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as temporary:
        work = Path(temporary)
        package = fetch_sources(work)
        catalog = work / "Phosphor"
        catalog.mkdir()
        (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        symbols, tints = {}, {}
        for name, weight, aliases, has_tint in SYMBOLS:
            suffix = "" if weight == "regular" else f"-{weight}"
            source = package / f"assets/{weight}/{name}{suffix}.svg"
            asset = f"ph.{name}" + (".fill" if weight == "fill" else "")
            converted, insets = convert(tool, source)
            write_symbol(catalog, asset, converted)
            for alias in aliases:
                if alias in symbols:
                    raise ValueError(f"Duplicate SF Symbol mapping: {alias}")
                symbols[alias] = asset
            if has_tint:
                tint_source = work / f"{name}-tint.svg"
                extract_tint(package / f"assets/duotone/{name}-duotone.svg", tint_source)
                converted, _ = convert(tool, tint_source, insets)
                write_symbol(catalog, asset + ".tint", converted)
                tints.update({alias: asset + ".tint" for alias in aliases})

        swift = work / "AppSymbolCatalog.generated.swift"
        swift.write_text(swift_catalog(symbols, tints))
        license_file = work / "Phosphor-Icons-LICENSE.txt"
        license_file.write_text((package / "LICENSE").read_text(encoding="utf-8"), encoding="utf-8")
        publish([
            (catalog, ROOT / "VoiceInk/Assets.xcassets/Phosphor"),
            (swift, ROOT / "VoiceInk/DesignSystem/Theme/AppSymbolCatalog.generated.swift"),
            (license_file, ROOT / "VoiceInk/Resources/Licenses/Phosphor-Icons-LICENSE.txt"),
        ], work)
    print(f"Generated {len(SYMBOLS)} symbols, {len(tints)} tint aliases and {len(symbols)} SF Symbol mappings (Phosphor {PHOSPHOR_VERSION})")


if __name__ == "__main__":
    main()
