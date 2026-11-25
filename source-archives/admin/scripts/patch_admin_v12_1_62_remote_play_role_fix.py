#!/usr/bin/env python3
"""Admin V12.1.62: expose Remote Play controls to the same Master/Owner roles as WoL.

The V12.1.61 UI hid its Remote Play tab because it accepted only ctx.role == "owner".
The existing canonical resolver also recognizes the project's Master/Owner aliases.
This additive patch delegates visibility and all existing Remote Play actions to it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_admin_v12_1_62_remote_play_role_fix.py <admin-project-dir>")

root = Path(sys.argv[1]).resolve()
page_path = root / "android/app/src/main/assets/web/admin.html"
gradle_path = root / "android/app/build.gradle"
manifest_path = root / "android/app/src/main/AndroidManifest.xml"

for path in (page_path, gradle_path, manifest_path):
    if not path.is_file():
        raise SystemExit("ADMIN_SOURCE_FILE_MISSING:" + str(path))

page = page_path.read_text(encoding="utf-8")
gradle = gradle_path.read_text(encoding="utf-8")
manifest = manifest_path.read_text(encoding="utf-8")

if "V12.1.52-REMOTE-PLAY-ADMIN-CONTROLS" not in page:
    raise SystemExit("REMOTE_PLAY_ADMIN_MODULE_MISSING")
if "V12.1.53-REMOTE-PLAY-SHARED-DB-PORT-8787" not in page:
    raise SystemExit("REMOTE_PLAY_SHARED_ANDROID_DB_ROUTE_MISSING")
if "function isWakeRelayOwner()" not in page:
    raise SystemExit("CANONICAL_MASTER_OWNER_RESOLVER_MISSING")

new = "function isRemotePlayOwner(){return typeof isWakeRelayOwner==='function'&&isWakeRelayOwner();}"
owner_pattern = re.compile(r"function\s+isRemotePlayOwner\s*\(\s*\)\s*\{[^}]*\}")
matches = list(owner_pattern.finditer(page))
if len(matches) == 1:
    page = page[:matches[0].start()] + new + page[matches[0].end():]
elif len(matches) == 0 and new in page:
    pass
else:
    raise SystemExit("REMOTE_PLAY_OWNER_GUARD_SHAPE_UNRECOGNIZED_OR_DUPLICATED")

# Confirm both the Remote Play tab and the Coin menu inherit the corrected guard.
for token in (
    'id="remotePlayAdminNav"',
    'id="coinManagementNav"',
    "function applyRemotePlayRoleUI()",
    "function tab(id)",
    "function coinAdminOwner(){return typeof isRemotePlayOwner==='function'&&isRemotePlayOwner()===true;}",
):
    if token not in page:
        raise SystemExit("ADMIN_ROLE_WIRING_MISSING:" + token)

tab_block = re.search(r"(?s)function\\s+tab\\s*\\(\\s*id\\s*\\)\\s*\\{(.*?)\\n\\}", page)
if not tab_block or "remotePlay" not in tab_block.group(1) or "isRemotePlayOwner()" not in tab_block.group(1):
    raise SystemExit("REMOTE_PLAY_TAB_NOT_GATED_BY_CANONICAL_OWNER_CHECK")

role_resolver = re.search(r"(?s)function isWakeRelayOwner\(\)\s*\{(.*?)\}", page)
if not role_resolver:
    raise SystemExit("CANONICAL_MASTER_OWNER_RESOLVER_BODY_MISSING")
for role in ("owner", "master", "master_owner", "owner_master", "master_admin", "admin_master", "super_admin", "superadmin"):
    if repr(role) not in role_resolver.group(1):
        raise SystemExit("CANONICAL_OWNER_ALIAS_MISSING:" + role)
owner_helper = owner_pattern.search(page)
if not owner_helper or "isWakeRelayOwner" not in owner_helper.group(0):
    raise SystemExit("REMOTE_PLAY_OWNER_HELPER_NOT_DELEGATING_TO_CANONICAL_RESOLVER")

if "com.anigames.billingadmin.v161online" not in gradle:
    raise SystemExit("ADMIN_PACKAGE_ID_MISMATCH")
if gradle.count("versionCode 88") != 1 or gradle.count("versionName '12.1.61-ANDROIDDB-COIN'") != 1:
    raise SystemExit("ADMIN_V12161_VERSION_ANCHOR_MISMATCH")
gradle = gradle.replace("versionCode 88", "versionCode 89", 1)
gradle = gradle.replace("versionName '12.1.61-ANDROIDDB-COIN'", "versionName '12.1.62-REMOTE-PLAY-ROLE-FIX'", 1)

manifest, count = re.subn(
    r'android:label="AniGames Admin V12\.1\.61 Android DB Coin"',
    'android:label="AniGames Admin V12.1.62 Remote Play"',
    manifest,
    count=1,
)
if count != 1:
    raise SystemExit("ADMIN_MANIFEST_LABEL_ANCHOR_MISMATCH")

page_path.write_text(page, encoding="utf-8")
gradle_path.write_text(gradle, encoding="utf-8")
manifest_path.write_text(manifest, encoding="utf-8")
(root / "VERSION.txt").write_text(
    "AniGames Admin V12.1.62 — Remote Play Admin visibility now uses the shared Master/Owner role resolver.\n",
    encoding="utf-8",
)
print("PASS: Remote Play Admin and Coin controls use the shared Master/Owner role resolver; V12.1.62 metadata applied.")
