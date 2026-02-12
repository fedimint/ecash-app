# Ecash App Release Process

## Release Candidates

- Create release branch (if new major/minor): `git checkout -b releases/vX.Y`
- Run the release script: `./scripts/release.sh X.Y.Z-rc.N`
  - Updates `pubspec.yaml` to `version: X.Y.Z-rc.N+VCODE`
  - Updates `rust/ecashapp/Cargo.toml` to `version = "X.Y.Z-rc.N"`
  - Commits and creates tag `vX.Y.Z-rc.N`
- Verify build: `just build-linux` and `flutter analyze`
- Push: `git push upstream releases/vX.Y && git push upstream vX.Y.Z-rc.N`
- Verify GitHub release created with APK and AppImage

## Final Release

- On release branch: `git checkout releases/vX.Y`
- Create final release branch: `git checkout -b releases/vX.Y.Z`
- Add F-Droid changelog: `metadata/en-US/changelogs/VCODE.txt` (max 500 chars)
- Commit any manual changes: `git commit -am "chore: prepare vX.Y.Z release"`
- Run the release script: `./scripts/release.sh X.Y.Z`
  - Updates `pubspec.yaml` to `version: X.Y.Z+VCODE`
  - Updates `rust/ecashapp/Cargo.toml` to `version = "X.Y.Z"`
  - Adds appstream release entry to `linux/appstream/org.fedimint.app.appdata.xml`
  - Commits and creates tag `vX.Y.Z`
- Push: `git push upstream releases/vX.Y.Z && git push upstream vX.Y.Z`
- Verify GitHub release created with APK and AppImage

## Post-Release

- Add branch protection to `releases/vX.Y` (first release only)
- PR the appstream release entry cherry-pick to `releases/vX.Y`
- PR to bump master to next alpha:
  - `pubspec.yaml`: `version: X.(Y+1).0-alpha`
  - `rust/ecashapp/Cargo.toml`: `version = "X.(Y+1).0-alpha"`
  - Include the appstream release entry cherry-pick

## Version Code Reference

The version code (VCODE) is calculated by `scripts/release.sh` and included in `pubspec.yaml` after a `+` suffix. This is required for F-Droid auto-update detection.

- RC: `VCODE = major*1000000 + minor*10000 + patch*100 + rc_num`
- Final: `VCODE = major*1000000 + minor*10000 + patch*100 + 90`

Examples:
- `0.5.0` → `version: 0.5.0+50090`
- `0.5.0-rc.1` → `version: 0.5.0-rc.1+50001`
- `1.0.0` → `version: 1.0.0+1000090`
