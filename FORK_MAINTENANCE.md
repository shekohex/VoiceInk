# Fork Maintenance Guide

This document explains how to keep your VoiceInk fork up to date with the upstream repository.

## Repository Setup

- **origin**: `git@github.com:shekohex/VoiceInk.git` (your fork)
- **upstream**: `git@github.com:Beingpax/VoiceInk.git` (original repository)

## Keeping Your Fork Updated

### 1. Fetch latest changes from upstream
```bash
git fetch upstream
```

### 2. Switch to your main branch
```bash
git checkout main
```

### 3. Merge upstream changes
```bash
git merge upstream/main
```

### 4. Push updates to your fork
```bash
git push origin main
```

## One-liner for regular updates
```bash
git fetch upstream && git checkout main && git merge upstream/main && git push origin main
```

## Working with Feature Branches

### Create a new feature branch from latest upstream
```bash
git fetch upstream
git checkout -b feature/your-feature-name upstream/main
```

### Keep feature branch updated with upstream
```bash
git fetch upstream
git rebase upstream/main
```

## Your Current Branches

- `main` - Your main branch with compatibility fixes
- `fix/macos-compatibility` - Feature branch for the macOS compatibility fix

## Notes

- Your `main` branch now contains the macOS compatibility fixes
- Both branches are pushed to your fork at `shekohex/VoiceInk`
- Always fetch from upstream before creating new feature branches
- Consider rebasing feature branches instead of merging to keep history clean