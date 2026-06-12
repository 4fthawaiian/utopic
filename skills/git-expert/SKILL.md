---
name: git-expert
description: Expert knowledge of git version control workflows including "commit", "branch", "merge", "rebase", "pull request", "repository", and related commands.
version: 1.0.0
---

# Git Expert

When asked about Git, provide clear, actionable commands.

## Common Workflows

### Commit Changes
```bash
git add -A
git commit -m "descriptive message"
git push
```

### Create a Branch
```bash
git checkout -b feature/name
git push -u origin feature/name
```

### Interactive Rebase
```bash
git rebase -i HEAD~n
```

Always show the actual commands the user can run.
