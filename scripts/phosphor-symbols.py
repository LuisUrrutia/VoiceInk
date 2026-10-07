#!/usr/bin/env python3
"""Regenerate VoiceInk's custom symbols with SwiftDraw 0.29.0."""

import argparse
import base64
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

# Phosphor outline name and legacy SF Symbol aliases.
SYMBOLS = [
    ("gauge", ["gauge.medium"]),
    ("house", ["house", "house.fill"]),
    ("stack", ["square.stack", "sparkles.square.fill.on.square"]),
    ("waveform", ["waveform", "waveform.path", "waveform.badge.magnifyingglass", "waveform.path.ecg"]),
    ("clock", ["clock", "clock.fill"]),
    ("book-open-text", ["text.book.closed", "character.book.closed", "text.book.closed.fill", "character.book.closed.fill"]),
    ("cpu", ["cpu", "cpu.fill"]),
    ("microphone", ["mic", "mic.fill", "microphone.fill"]),
    ("gear-six", ["gearshape", "gearshape.fill"]),
    ("seal-check", ["checkmark.seal", "checkmark.seal.fill"]),
    ("file-text", ["doc.text.fill", "doc.text"]),
    ("x", ["xmark"]),
    ("globe", ["globe"]),
    ("sparkle", ["sparkles"]),
    ("check", ["checkmark"]),
    ("check-circle", ["checkmark.circle", "checkmark.circle.fill"]),
    ("x-circle", ["xmark.circle", "xmark.circle.fill"]),
    ("warning", ["exclamationmark.triangle", "exclamationmark.triangle.fill"]),
    ("info", ["info.circle", "info.circle.fill"]),
    ("arrow-right", ["arrow.right"]),
    ("arrow-up-right", ["arrow.up.right"]),
    ("arrow-clockwise", ["arrow.clockwise", "arrow.clockwise.circle.fill"]),
    ("arrow-counter-clockwise", ["arrow.counterclockwise"]),
    ("trash", ["trash"]),
    ("folder", ["folder"]),
    ("dots-three-circle", ["ellipsis.circle"]),
    ("plus-circle", ["plus.circle", "plus.circle.fill"]),
    ("pencil-simple", ["pencil"]),
    ("pencil-circle", ["pencil.circle.fill"]),
    ("note-pencil", ["square.and.pencil", "long.text.page.and.pencil.fill"]),
    ("caret-right", ["chevron.right"]),
    ("caret-left", ["chevron.left"]),
    ("caret-down", ["chevron.down"]),
    ("caret-up", ["chevron.up"]),
    ("caret-up-down", ["chevron.up.chevron.down"]),
    ("magnifying-glass", ["magnifyingglass"]),
    ("hard-drive", ["internaldrive", "internaldrive.fill"]),
    ("chart-bar", ["chart.bar.xaxis", "chart.bar"]),
    ("magic-wand", ["wand.and.stars"]),
    ("squares-four", ["square.grid.2x2", "square.grid.2x2.fill"]),
    ("play", ["play.fill"]),
    ("copy", ["doc.on.doc"]),
    ("calendar", ["calendar", "1.calendar"]),
    ("terminal-window", ["apple.terminal.fill", "terminal"]),
    ("archive", ["archivebox.fill"]),
    ("handbag", ["bag.fill"]),
    ("messenger-logo", ["bolt.horizontal.circle.fill"]),
    ("notebook", ["book.pages.fill"]),
    ("briefcase", ["briefcase.fill"]),
    ("chats", ["bubble.left.and.text.bubble.right.fill", "bubble.left.and.bubble.right.fill", "bubble.left.and.bubble.right"]),
    ("bank", ["building.columns.circle.fill"]),
    ("camera", ["camera.fill"]),
    ("subtitles", ["captions.bubble.fill", "captions.bubble"]),
    ("currency-circle-dollar", ["dollarsign.bank.building.fill"]),
    ("envelope", ["envelope.fill", "envelope"]),
    ("flask", ["flask.fill"]),
    ("graduation-cap", ["graduationcap.fill"]),
    ("keyboard", ["keyboard.fill", "keyboard"]),
    ("lightbulb-filament", ["lightbulb.max.fill"]),
    ("newspaper", ["magazine.fill"]),
    ("map-trifold", ["map.fill"]),
    ("music-notes", ["music.pages"]),
    ("paint-brush", ["paintbrush.pointed.fill"]),
    ("phone-call", ["phone.bubble.fill"]),
    ("images", ["photo.fill.on.rectangle.fill"]),
    ("monitor-play", ["play.rectangle.fill"]),
    ("quotes", ["quote.bubble.fill"]),
    ("receipt", ["receipt.fill"]),
    ("star-four", ["star.hexagon.fill"]),
    ("tray", ["tray.full.fill"]),
    ("tree", ["tree.fill"]),
    ("wallet", ["wallet.bifold.fill"]),
    ("apple-logo", ["apple.logo"]),
    ("app-window", ["app.fill"]),
    ("arrows-clockwise", ["arrow.2.squarepath", "rectangle.2.swap"]),
    ("arrow-circle-down", ["arrow.down.circle", "arrow.down.circle.fill"]),
    ("file-arrow-down", ["arrow.down.doc"]),
    ("arrows-left-right", ["arrow.left.arrow.right"]),
    ("arrow-circle-up-right", ["arrow.up.right.circle.fill"]),
    ("arrow-square-out", ["arrow.up.right.square"]),
    ("arrow-u-up-left", ["arrow.uturn.backward"]),
    ("lightning", ["bolt.fill", "bolt.circle.fill"]),
    ("book", ["book.fill"]),
    ("chart-bar-horizontal", ["chart.bar.doc.horizontal"]),
    ("chart-line-up", ["chart.line.uptrend.xyaxis"]),
    ("shield-check", ["checkmark.shield", "lock.shield"]),
    ("code", ["chevron.left.forwardslash.chevron.right"]),
    ("circle", ["circle"]),
    ("circle-dashed", ["circle.dashed"]),
    ("cloud", ["cloud.fill"]),
    ("command", ["command.circle"]),
    ("cube", ["cube"]),
    ("clipboard-text", ["doc.on.clipboard", "list.bullet.clipboard.fill"]),
    ("file-magnifying-glass", ["doc.text.magnifyingglass"]),
    ("chat-centered-dots", ["exclamationmark.bubble.fill"]),
    ("warning-circle", ["exclamationmark.circle", "exclamationmark.circle.fill"]),
    ("hand-palm", ["hand.raised"]),
    ("hourglass", ["hourglass"]),
    ("infinity", ["infinity"]),
    ("key", ["key.fill"]),
    ("link", ["link", "link.badge.plus"]),
    ("list-bullets", ["list.bullet.rectangle"]),
    ("lock-key", ["lock.fill"]),
    ("laptop", ["macbook"]),
    ("microphone-slash", ["mic.slash"]),
    ("minus-circle", ["minus.circle", "minus.circle.fill"]),
    ("note", ["note.text"]),
    ("hash", ["number"]),
    ("paper-plane-tilt", ["paperplane.fill"]),
    ("pause", ["pause.fill"]),
    ("user-circle-check", ["person.crop.circle.badge.checkmark"]),
    ("plus", ["plus"]),
    ("hard-drives", ["server.rack"]),
    ("shield", ["shield", "shield.fill"]),
    ("sidebar", ["sidebar.left"]),
    ("sidebar-simple", ["sidebar.right"]),
    ("prohibit", ["slash.circle.fill"]),
    ("sliders-horizontal", ["slider.horizontal.3"]),
    ("download-simple", ["square.and.arrow.down"]),
    ("export", ["square.and.arrow.up"]),
    ("star", ["star"]),
    ("stop", ["stop.fill"]),
    ("text-align-left", ["text.alignleft"]),
    ("chat-text", ["text.bubble", "text.bubble.fill"]),
    ("cursor-text", ["text.cursor"]),
    ("timer", ["timer"]),
    ("video-camera", ["video.fill"]),
    ("wifi-high", ["wifi"]),
    ("trash-simple", ["xmark.bin"]),
    ("warning-octagon", ["xmark.octagon.fill"]),
    ("shopping-cart", ["cart.fill"]),
    ("question", ["questionmark"]),
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
    for name, _ in SYMBOLS:
        paths.add(f"assets/regular/{name}.svg")
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


def convert(tool, source):
    command = [str(tool), str(source), "--format", "sfsymbol"]
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
    alignment = re.search(r"Alignment: --insets (\S+)", result.stdout)
    if alignment is None:
        raise ValueError(f"SwiftDraw did not report alignment for {source.name}")
    output = source.with_name(source.stem + "-symbol.svg")
    ET.parse(output)
    return output


def write_symbol(catalog, name, source):
    folder = catalog / f"{name}.symbolset"
    folder.mkdir()
    shutil.copyfile(source, folder / f"{name}.svg")
    metadata = {
        "info": {"author": "xcode", "version": 1},
        "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}],
    }
    (folder / "Contents.json").write_text(json.dumps(metadata, indent=2) + "\n")


def swift_catalog(symbols):
    lines = ["// Generated by scripts/phosphor-symbols.py. Do not edit.", "", "enum AppSymbolCatalog {"]
    lines += ['    static let fallback = "ph.question"', ""]
    lines.append("    static let symbols: [String: String] = [")
    lines.extend(f'        "{key}": "{value}",' for key, value in sorted(symbols.items()))
    lines.append("    ]")
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
        symbols = {}
        for name, aliases in SYMBOLS:
            source = package / f"assets/regular/{name}.svg"
            if name == "sidebar-simple":
                # Phosphor's sidebar faces left; the inspector toggle faces right.
                root = ET.parse(source).getroot()
                shapes = list(root)
                root.clear()
                root.attrib.update({"viewBox": "0 0 256 256", "fill": "currentColor"})
                group = ET.SubElement(root, f"{{{SVG_NAMESPACE}}}g", {"transform": "translate(256 0) scale(-1 1)"})
                group.extend(shapes)
                ET.register_namespace("", SVG_NAMESPACE)
                ET.ElementTree(root).write(source, encoding="utf-8", xml_declaration=True)
            asset = f"ph.{name}"
            converted = convert(tool, source)
            write_symbol(catalog, asset, converted)
            for alias in aliases:
                if alias in symbols:
                    raise ValueError(f"Duplicate SF Symbol mapping: {alias}")
                symbols[alias] = asset
        swift = work / "AppSymbolCatalog.generated.swift"
        swift.write_text(swift_catalog(symbols))
        license_file = work / "Phosphor-Icons-LICENSE.txt"
        license_file.write_text((package / "LICENSE").read_text(encoding="utf-8"), encoding="utf-8")
        publish([
            (catalog, ROOT / "VoiceInk/Assets.xcassets/Phosphor"),
            (swift, ROOT / "VoiceInk/DesignSystem/Theme/AppSymbolCatalog.generated.swift"),
            (license_file, ROOT / "VoiceInk/Resources/Licenses/Phosphor-Icons-LICENSE.txt"),
        ], work)
    print(f"Generated {len(SYMBOLS)} outlined symbols and {len(symbols)} SF Symbol mappings (Phosphor {PHOSPHOR_VERSION})")


if __name__ == "__main__":
    main()
