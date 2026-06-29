#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[1]
PROJECT = APP_ROOT / "PasswordManagerWindows.vcxproj"
VCPKG_MANIFEST = APP_ROOT / "vcpkg.json"
README = APP_ROOT / "README.md"
MSBUILD_NS = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] {message}")


def ok(message: str) -> None:
    print(f"[OK] {message}")


def require(condition: bool, message: str) -> None:
    if condition:
        ok(message)
    else:
        fail(message)


def normalize(value: str | None) -> str:
    return (value or "").strip()


def normalize_path(value: str) -> str:
    return value.replace("/", "\\").lower()


def text_values(root: ET.Element, tag: str) -> list[str]:
    return [
        normalize(node.text)
        for node in root.findall(f".//msb:{tag}", MSBUILD_NS)
        if normalize(node.text)
    ]


def has_text(root: ET.Element, tag: str, expected: str) -> bool:
    return any(value.lower() == expected.lower() for value in text_values(root, tag))


def item_includes(root: ET.Element, tag: str) -> set[str]:
    return {
        normalize_path(node.attrib.get("Include", ""))
        for node in root.findall(f".//msb:{tag}", MSBUILD_NS)
        if normalize(node.attrib.get("Include", ""))
    }


def release_item_definition(root: ET.Element) -> ET.Element:
    for group in root.findall("msb:ItemDefinitionGroup", MSBUILD_NS):
        if normalize(group.attrib.get("Condition")) == "'$(Configuration)|$(Platform)'=='Release|x64'":
            return group
    fail("Missing Release|x64 ItemDefinitionGroup")


def child_text(parent: ET.Element, path: str) -> str:
    node = parent.find(path, MSBUILD_NS)
    return normalize(node.text if node is not None else "")


def check_vcpkg_manifest() -> None:
    require(VCPKG_MANIFEST.exists(), "vcpkg manifest exists")
    manifest = json.loads(VCPKG_MANIFEST.read_text(encoding="utf-8"))
    dependencies = manifest.get("dependencies", [])
    names = {
        item if isinstance(item, str) else item.get("name", "")
        for item in dependencies
    }
    require(manifest.get("name") == "passwordmanager-windows-native", "vcpkg package name is stable")
    require("openssl" in names, "vcpkg manifest declares OpenSSL")
    require("curl" in names, "vcpkg manifest declares libcurl")


def check_vcxproj() -> None:
    require(PROJECT.exists(), "Visual Studio project exists")
    root = ET.parse(PROJECT).getroot()

    configs = {
        normalize(node.attrib.get("Include"))
        for node in root.findall(".//msb:ProjectConfiguration", MSBUILD_NS)
    }
    require("Debug|x64" in configs, "Debug|x64 configuration exists")
    require("Release|x64" in configs, "Release|x64 configuration exists")

    require(has_text(root, "ConfigurationType", "Application"), "project builds an application")
    require(has_text(root, "UseDebugLibraries", "false"), "Release disables debug libraries")
    require(has_text(root, "PlatformToolset", "v143"), "MSVC v143 toolset is configured")
    require(has_text(root, "WholeProgramOptimization", "true"), "Release enables whole program optimization")
    require(has_text(root, "CharacterSet", "Unicode"), "project uses Unicode character set")

    require(has_text(root, "VcpkgEnabled", "true"), "vcpkg integration is enabled")
    require(has_text(root, "VcpkgEnableManifest", "true"), "vcpkg manifest mode is enabled")
    require(has_text(root, "VcpkgManifestInstall", "true"), "vcpkg manifest install is enabled")
    require(has_text(root, "VcpkgTriplet", "x64-windows"), "vcpkg triplet is x64-windows")
    require(has_text(root, "VcpkgApplocalDeps", "true"), "vcpkg app-local dependency copy is enabled")

    compile_items = item_includes(root, "ClCompile")
    include_items = item_includes(root, "ClInclude")
    for source in [
        r"src\win32_app.cpp",
        r"..\native_core\src\vault_core.cpp",
        r"..\native_core\src\vault_cli.cpp",
    ]:
        require(normalize_path(source) in compile_items, f"project compiles {source}")
    for header in [
        r"..\native_core\src\vault_core.hpp",
        r"..\native_core\src\vault_cli.hpp",
    ]:
        require(normalize_path(header) in include_items, f"project references {header}")

    release = release_item_definition(root)
    release_compile = release.find("msb:ClCompile", MSBUILD_NS)
    release_link = release.find("msb:Link", MSBUILD_NS)
    require(release_compile is not None, "Release ClCompile settings exist")
    require(release_link is not None, "Release Link settings exist")

    include_dirs = child_text(release_compile, "msb:AdditionalIncludeDirectories")
    require(r"..\native_core\src" in include_dirs, "Release include path references shared native core")
    require(child_text(release_compile, "msb:RuntimeLibrary") == "MultiThreadedDLL", "Release uses dynamic CRT")
    require(child_text(release_compile, "msb:SDLCheck") == "true", "Release enables SDL checks")
    require(child_text(release_compile, "msb:ConformanceMode") == "true", "Release enables MSVC conformance mode")
    require(child_text(release_compile, "msb:ExceptionHandling") == "Sync", "Release enables synchronous C++ exceptions")
    require("NDEBUG" in child_text(release_compile, "msb:PreprocessorDefinitions"), "Release defines NDEBUG")

    dependencies = child_text(release_link, "msb:AdditionalDependencies")
    for library in ["libcrypto.lib", "libssl.lib", "libcurl.lib"]:
        require(library in dependencies, f"Release links {library}")
    require(child_text(release_link, "msb:GenerateDebugInformation") == "true", "Release emits debug information")
    require(child_text(release_link, "msb:OptimizeReferences") == "true", "Release optimizes unreferenced code")
    require(child_text(release_link, "msb:EnableCOMDATFolding") == "true", "Release enables COMDAT folding")


def check_readme() -> None:
    require(README.exists(), "README exists")
    text = README.read_text(encoding="utf-8")
    for needle in [
        "scripts/verify_release_contract.py",
        "vcpkg.json",
        "VcpkgEnableManifest",
        "x64-windows",
        "Visual Studio / MSBuild release contract",
        "Windows 实机 MSBuild",
    ]:
        require(needle in text, f"README documents {needle}")


def main() -> None:
    check_vcpkg_manifest()
    check_vcxproj()
    check_readme()
    print("[OK] Windows release contract verification completed")


if __name__ == "__main__":
    try:
        main()
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON in {VCPKG_MANIFEST}: {exc}")
    except ET.ParseError as exc:
        fail(f"Invalid XML in {PROJECT}: {exc}")
