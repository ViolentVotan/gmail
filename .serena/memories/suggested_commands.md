# Suggested Commands

## Build
- XcodeBuildMCP for compilation verification (preferred)
- `xcodebuild build -scheme Serif -destination 'platform=macOS'`

## Test
- `xcodebuild test -scheme Serif -destination 'platform=macOS'`

## Release
- Push a `v*` tag to trigger CI release pipeline
- Manual: `scripts/release.sh`

## Clean
- `xcodebuild clean -scheme Serif`
- Remove DerivedData: `rm -r ~/Library/Developer/Xcode/DerivedData/Serif-*`
