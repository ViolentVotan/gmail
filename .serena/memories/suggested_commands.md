# Suggested Commands

## Build
- `xcodebuild -scheme Vik -configuration Debug build`

## Test
- `xcodebuild test -scheme Vik -destination 'platform=macOS'`

## Release
- Push a `v*` tag to trigger CI release pipeline
- Manual: `scripts/release.sh`

## Clean
- `xcodebuild clean -scheme Vik`
- Remove DerivedData: `rm -r ~/Library/Developer/Xcode/DerivedData/Vik-*`
