# ClipThat launch runbook

Everything that needs your GitHub account + a couple of your decisions. ~10–15 minutes.
Work top to bottom. Replace `<you>` with your GitHub username throughout.

## 0. One-time setup (GitHub CLI + identity)

```sh
brew install gh
gh auth login                       # GitHub.com → HTTPS → log in via browser
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

## 1. Drop your GitHub username into the site + cask

```sh
cd /Users/yana/Documents/Afterclip
grep -rl YOUR_USERNAME docs packaging | xargs sed -i '' "s/YOUR_USERNAME/<you>/g"
```

## 2. (High-impact, optional) Add a demo clip + icon

- Record a 5–10s clip in a game: press ⌥⌘C to save, then save it as `docs/demo.mp4`,
  and uncomment the `<video>` line in `docs/index.html` (search for `demo.mp4`).
- Drop a 1024×1024 `docs/icon.png` if you want a real icon in the hero.

## 3. Create the main repo + push

```sh
cd /Users/yana/Documents/Afterclip
git add -A
git commit -m "ClipThat: rebrand, 120fps/4K, numbered clips, landing page"
gh repo create clipthat --public --source=. --remote=origin --push
```

## 4. Turn on the website (free, GitHub Pages)

```sh
gh api -X POST repos/<you>/clipthat/pages -f "source[branch]=main" -f "source[path]=/docs"
```

Live in ~1 min at **https://<you>.github.io/clipthat** — open it and confirm the orb loads.

## 5. Build the release artifact + get its sha256

```sh
./scripts/release.sh          # prints version + sha256
```

## 6. Cut the GitHub release with the app attached

```sh
gh release create v0.1.0 ClipThat.zip -t "ClipThat 0.1.0" -n "First public release."
```

## 7. Publish the Homebrew tap

```sh
# paste the sha256 from step 5 into packaging/homebrew-tap/Casks/clipthat.rb first, then:
cd packaging/homebrew-tap
git init && git add -A && git commit -m "ClipThat cask"
gh repo create homebrew-clipthat --public --source=. --remote=origin --push
# test the whole flow:
brew tap <you>/clipthat
brew install --cask clipthat
```

## 8. Re-sign the app for yourself (bundle ID changed in the rebrand)

```sh
cd /Users/yana/Documents/Afterclip
./scripts/setup-signing.sh && ./scripts/install.sh
# then re-grant Screen Recording to "ClipThat" in System Settings
```

## 9. Post to Reddit

- Confirm both the site and the GitHub repo load (no 404s).
- Post to **r/macgaming** with the title + body from our chat (links are now real).
- Camp the comments for the first couple hours.

---

### Still to reconcile before launch
- Min macOS version: build says 15.0, but README + site say "14.2+". Pick one.
- The `~/Movies/Afterclip` folder still holds your old clips (incl. CLIP NO. 1.mp4) — the
  renamed app now writes to `~/Movies/ClipThat`. Move them over if you want them.
