# ClipThat Homebrew tap

The contents of this folder become a **separate GitHub repo** that must be named
`homebrew-clipthat` (Homebrew requires the `homebrew-` prefix; users then tap it as
`Bhavyaapple24-ai/clipthat`).

## Install (what your users run)

```sh
brew tap Bhavyaapple24-ai/clipthat
brew install --cask clipthat
```

The cask downloads the latest GitHub release from the main `clipthat` repo, installs
`ClipThat.app`, and strips the macOS quarantine flag so it opens without the
"app is damaged" warning. (ClipThat isn't notarized yet — that needs the $99 Apple
Developer Program. A custom tap is allowed to strip quarantine; homebrew-core is not.)

## Publishing the tap

```sh
cd packaging/homebrew-tap
git init && git add -A && git commit -m "ClipThat cask"
gh repo create homebrew-clipthat --public --source=. --remote=origin --push
```

## Updating for a new release

1. In the main repo: `./scripts/release.sh` → builds `ClipThat.zip`, prints the sha256.
2. Upload `ClipThat.zip` to a GitHub release (`gh release create vX.Y.Z ClipThat.zip …`).
3. Bump `version` and `sha256` in `Casks/clipthat.rb`, commit, push.
