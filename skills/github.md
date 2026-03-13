# GitHub CLI Skills

You have access to the `gh` command line tool for GitHub operations.

## Common Operations

### Repository
- `gh repo create <name> --public` - Create a new repo
- `gh repo clone <owner/repo>` - Clone a repo
- `gh repo view` - View current repo info

### Pull Requests
- `gh pr create --title "..." --body "..."` - Create a PR
- `gh pr list` - List open PRs
- `gh pr view <number>` - View a PR
- `gh pr merge <number>` - Merge a PR
- `gh pr checkout <number>` - Check out a PR locally

### Issues
- `gh issue create --title "..." --body "..."` - Create an issue
- `gh issue list` - List open issues
- `gh issue close <number>` - Close an issue

### Workflow
- `gh run list` - List recent workflow runs
- `gh run view <id>` - View a workflow run

## Guidelines
- Always create descriptive PR titles and bodies
- Use `--body` for multi-line descriptions
- Check existing PRs/issues before creating duplicates
