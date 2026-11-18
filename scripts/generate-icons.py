#!/usr/bin/env python3
"""Regenerate the graphite app icon and canonical menu bar template."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGNS = ROOT / "design" / "canonical"
RESOURCES = ROOT / "Resources"
APP_SVG = DESIGNS / "AppIcon-Light.svg"
APP_DARK_SVG = DESIGNS / "AppIcon-Dark.svg"
APP_ICNS = RESOURCES / "AppIcon.icns"
APP_DARK_PNG = RESOURCES / "AppIconDark.png"
SVG_RENDERER = ROOT / "scripts" / "render-svg-png.swift"
MENU_1X = RESOURCES / "MenuIcon.png"
MENU_2X = RESOURCES / "MenuIcon@2x.png"
MENU_RENDERER = ROOT / "scripts" / "render-menu-icon.swift"


def tool(name: str) -> str:
    result = shutil.which(name)
    if not result:
        raise SystemExit(f"Required macOS tool not found: {name}")
    return result


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def render_app_svg(source: Path, destination: Path) -> None:
    overlay = subprocess.check_output([sys.executable, str(ROOT / "scripts" / "prepare-toolchain.py")], text=True).strip()
    module_cache = ROOT / ".build" / "AppIconModuleCache"
    module_cache.mkdir(parents=True, exist_ok=True)
    run(tool("xcrun"), "swift", "-module-cache-path", str(module_cache),
        "-Xfrontend", "-vfsoverlay", "-Xfrontend", overlay,
        "-Xcc", "-ivfsoverlay", "-Xcc", overlay,
        str(SVG_RENDERER), str(source), str(destination))


def generate_menu() -> None:
    if not MENU_RENDERER.is_file():
        raise SystemExit("Missing canonical native menu renderer")
    RESOURCES.mkdir(exist_ok=True)
    qa_path = Path(tempfile.gettempdir()) / "LayoutSwitcher-menu-icon-qa.png"
    if "--qa-preview" in sys.argv[1:]:
        index = sys.argv.index("--qa-preview")
        if index + 1 >= len(sys.argv):
            raise SystemExit("--qa-preview requires a file path")
        qa_path = Path(sys.argv[index + 1]).expanduser().resolve()
        qa_path.parent.mkdir(parents=True, exist_ok=True)
    cache_dir = Path(tempfile.gettempdir()) / "layout-switcher-swift-module-cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    overlay = subprocess.check_output([sys.executable, str(ROOT / "scripts" / "prepare-toolchain.py")], text=True).strip()
    run(tool("xcrun"), "swift", "-module-cache-path", str(cache_dir),
        "-Xfrontend", "-vfsoverlay", "-Xfrontend", overlay,
        "-Xcc", "-ivfsoverlay", "-Xcc", overlay,
        str(MENU_RENDERER), str(MENU_1X), str(MENU_2X), str(qa_path))
    print(f"Generated {MENU_1X} (32x18)")
    print(f"Generated {MENU_2X} (64x36)")
    print(f"QA preview {qa_path}")


def generate_app() -> None:
    for source in (APP_SVG, APP_DARK_SVG):
        if not source.is_file():
            raise SystemExit(f"Missing app icon artwork: {source}")
    sips, iconutil = (tool(name) for name in ("sips", "iconutil"))
    RESOURCES.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="layout-switcher-icons-") as tmp:
        tmpdir = Path(tmp)
        app_png = tmpdir / "app-1024.png"
        dark_png = tmpdir / "app-dark.png"
        iconset = tmpdir / "AppIcon.iconset"
        iconset.mkdir()

        # AppKit's SVG renderer preserves gradients and alpha; ImageMagick's
        # built-in SVG delegate may flatten or drop gradient fills.
        render_app_svg(APP_SVG, app_png)
        render_app_svg(APP_DARK_SVG, dark_png)
        for base in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = base * scale
                name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
                run(sips, "-z", str(px), str(px), str(app_png), "--out", str(iconset / name))
        run(iconutil, "-c", "icns", str(iconset), "-o", str(APP_ICNS))
        run(sips, "-z", "1024", "1024", str(dark_png), "--out", str(APP_DARK_PNG))

    print(f"Generated {APP_ICNS}")
    print(f"Generated {APP_DARK_PNG}")


def main() -> None:
    menu_only = "--menu-only" in sys.argv[1:]
    app_only = "--app-only" in sys.argv[1:]
    args = sys.argv[1:]
    unknown = []
    i = 0
    while i < len(args):
        if args[i] in ("--menu-only", "--app-only"):
            i += 1
        elif args[i] == "--qa-preview" and i + 1 < len(args):
            i += 2
        else:
            unknown.append(args[i])
            i += 1
    if unknown:
        raise SystemExit(f"Unknown argument: {unknown[0]}")
    if app_only and menu_only:
        raise SystemExit("Choose only one of --app-only or --menu-only")
    if not menu_only:
        generate_app()
    if not app_only:
        generate_menu()


if __name__ == "__main__":
    main()
