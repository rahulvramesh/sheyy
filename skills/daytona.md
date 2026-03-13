# Daytona Development Environment Skills

You have access to the `daytona` CLI for managing development environments.

## Common Operations

### Workspace Management
- `daytona create <repo-url>` - Create a new workspace from a Git repo
- `daytona list` - List all workspaces
- `daytona start <workspace>` - Start a workspace
- `daytona stop <workspace>` - Stop a workspace
- `daytona delete <workspace>` - Delete a workspace

### Code Execution
- `daytona code <workspace>` - Open workspace in IDE
- `daytona ssh <workspace>` - SSH into workspace

### Configuration
- `daytona target list` - List available targets
- `daytona provider list` - List available providers

## Guidelines
- Always check if a workspace exists before creating a new one
- Stop workspaces when done to save resources
- Use descriptive names for workspaces
