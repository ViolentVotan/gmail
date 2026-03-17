# Suggested Commands

## Build
- XcodeBuildMCP for compilation verification (preferred)
- `xcodebuild build -scheme Vik -destination 'platform=macOS'`

## Test
- `xcodebuild test -scheme Vik -destination 'platform=macOS'`

## Release
- Push a `v*` tag to trigger CI release pipeline
- Manual: `scripts/release.sh`

## Clean
- `xcodebuild clean -scheme Vik`
- Remove DerivedData: `rm -r ~/Library/Developer/Xcode/DerivedData/Vik-*`
