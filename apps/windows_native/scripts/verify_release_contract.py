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
APP_MANIFEST = APP_ROOT / "src" / "PasswordManagerWindows.manifest"
RESOURCE_HEADER = APP_ROOT / "src" / "resource.h"
RESOURCE_SCRIPT = APP_ROOT / "src" / "app.rc"
MSBUILD_NS = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}
MANIFEST_NS = {
    "asmv1": "urn:schemas-microsoft-com:asm.v1",
    "asmv3": "urn:schemas-microsoft-com:asm.v3",
    "compat": "urn:schemas-microsoft-com:compatibility.v1",
    "win2016": "http://schemas.microsoft.com/SMI/2016/WindowsSettings",
}


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
    resource_items = item_includes(root, "ResourceCompile")
    manifest_items = item_includes(root, "Manifest")
    for source in [
        r"src\win32_app.cpp",
        r"..\native_core\src\vault_core.cpp",
        r"..\native_core\src\vault_cli.cpp",
    ]:
        require(normalize_path(source) in compile_items, f"project compiles {source}")
    for header in [
        r"..\native_core\src\vault_core.hpp",
        r"..\native_core\src\vault_cli.hpp",
        r"src\resource.h",
    ]:
        require(normalize_path(header) in include_items, f"project references {header}")
    require(normalize_path(r"src\app.rc") in resource_items, "project compiles Windows version resource")
    require(normalize_path(r"src\PasswordManagerWindows.manifest") in manifest_items, "project embeds Windows application manifest")

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


def check_app_manifest() -> None:
    require(APP_MANIFEST.exists(), "Windows application manifest exists")
    root = ET.parse(APP_MANIFEST).getroot()

    identity = root.find("asmv1:assemblyIdentity", MANIFEST_NS)
    require(identity is not None, "manifest declares assembly identity")
    if identity is None:
        fail("Manifest identity parsing failed")
    require(identity.attrib.get("name") == "DevOpsLife.PasswordManager.Windows", "manifest identity name is stable")
    require(identity.attrib.get("version") == "0.1.0.0", "manifest identity version is stable")
    require(identity.attrib.get("type") == "win32", "manifest identity type is win32")
    require(identity.attrib.get("processorArchitecture") == "*", "manifest supports architecture-specific builds")

    description = root.findtext("asmv1:description", default="", namespaces=MANIFEST_NS)
    require(description == "Password Manager Windows Native", "manifest description is product-specific")

    execution_level = root.find(".//asmv3:requestedExecutionLevel", MANIFEST_NS)
    require(execution_level is not None, "manifest declares UAC execution level")
    if execution_level is None:
        fail("Manifest execution level parsing failed")
    require(execution_level.attrib.get("level") == "asInvoker", "manifest uses asInvoker UAC level")
    require(execution_level.attrib.get("uiAccess") == "false", "manifest disables UIAccess")

    supported_os = root.find(".//compat:supportedOS", MANIFEST_NS)
    require(supported_os is not None, "manifest declares Windows compatibility")
    if supported_os is None:
        fail("Manifest supportedOS parsing failed")
    require(
        supported_os.attrib.get("Id") == "{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}",
        "manifest declares Windows 10/11 compatibility GUID",
    )

    long_path = root.find(".//win2016:longPathAware", MANIFEST_NS)
    require(long_path is not None and normalize(long_path.text).lower() == "true", "manifest enables long path awareness")


def check_version_resource() -> None:
    require(RESOURCE_HEADER.exists(), "Windows resource header exists")
    require(RESOURCE_SCRIPT.exists(), "Windows version resource script exists")
    header = RESOURCE_HEADER.read_text(encoding="utf-8")
    script = RESOURCE_SCRIPT.read_text(encoding="utf-8")

    for needle in [
        '#define IDS_APP_NAME 101',
        '#define IDS_COMPANY_NAME 102',
        '#define VER_FILE_VERSION 0,1,0,0',
        '#define VER_FILE_VERSION_STR "0.1.0.0\\0"',
        '#define VER_PRODUCT_VERSION 0,1,0,0',
        '#define VER_PRODUCT_VERSION_STR "0.1.0\\0"',
    ]:
        require(needle in header, f"resource header declares {needle}")

    for needle in [
        '#include "resource.h"',
        "#include <winver.h>",
        "VS_VERSION_INFO VERSIONINFO",
        'IDS_APP_NAME "Password Manager"',
        'IDS_COMPANY_NAME "DevOps Life"',
        'VALUE "CompanyName", "DevOps Life\\0"',
        'VALUE "FileDescription", "Password Manager Windows Native\\0"',
        'VALUE "InternalName", "PasswordManagerWindows.exe\\0"',
        'VALUE "OriginalFilename", "PasswordManagerWindows.exe\\0"',
        'VALUE "ProductName", "Password Manager\\0"',
    ]:
        require(needle in script, f"version resource declares {needle}")


def check_readme() -> None:
    require(README.exists(), "README exists")
    text = README.read_text(encoding="utf-8")
    for needle in [
        "scripts/verify_release_contract.py",
        "vcpkg.json",
        "PasswordManagerWindows.manifest",
        "VERSIONINFO",
        "VcpkgEnableManifest",
        "x64-windows",
        "Visual Studio / MSBuild release contract",
        "Windows 实机 MSBuild",
    ]:
        require(needle in text, f"README documents {needle}")


def main() -> None:
    check_vcpkg_manifest()
    check_vcxproj()
    check_app_manifest()
    check_version_resource()
    check_readme()
    print("[OK] Windows release contract verification completed")


if __name__ == "__main__":
    try:
        main()
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON in {VCPKG_MANIFEST}: {exc}")
    except ET.ParseError as exc:
        fail(f"Invalid XML in {PROJECT}: {exc}")
