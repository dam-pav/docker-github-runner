# GitHub Actions Runner (container)

This image packages a self-hosted GitHub Actions runner for Linux x64.

Build

```bash
docker build -t github-runner:2.331.0 .
```

Run (register and start the runner)

Provide `RUNNER_URL` and either `GITHUB_TOKEN` (recommended) or `RUNNER_TOKEN` environment variables. `GITHUB_TOKEN` is a GitHub PAT used to request a short-lived registration token from the GitHub API at container start; `RUNNER_TOKEN` may still be provided directly for compatibility.

Example (using a PAT):

```bash
docker run --rm -e RUNNER_URL=https://github.com/dam-pav/acme-worker \
  -e GITHUB_TOKEN=ghp_xxx... \
  --name my-runner github-runner:2.331.0
```

On container start the image will request a registration token via the GitHub API (using `GITHUB_TOKEN`) and register the runner. When the container stops it will attempt to deregister the runner automatically, making the runner effectively ephemeral.

Environment variables

- `RUNNER_URL` (required): URL of the organization or repository, e.g. `https://github.com/owner/repo`
- `GITHUB_TOKEN` (recommended): GitHub Personal Access Token (PAT) used to request a registration token via the API. For repository runners it needs `repo` scope; for organization runners it needs `admin:org` (or equivalent) scope.
- `RUNNER_TOKEN` (optional): direct registration token (if you prefer not to use a PAT)
- `RUNNER_NAME` (optional): runner name; defaults to container hostname
- `RUNNER_WORKDIR` (optional): work directory inside the runner; defaults to `_work`
- `RUNNER_LABELS` (optional): comma-separated labels

Notes

- The image downloads the runner release defined by `RUNNER_VERSION` in the `Dockerfile`.

Retries and API configuration

- The entrypoint performs GitHub API calls (requesting registration tokens, listing and deleting runners) with retry and exponential backoff. You can tune behavior with these env vars (defaults shown in `.env.example`):
  - `GH_API_RETRIES`: number of attempts for API calls (default `6`)
  - `GH_API_INITIAL_DELAY`: initial delay in seconds between retries (default `1`)
  - `GH_API_BACKOFF_MULT`: exponential backoff multiplier (default `2`)
  - Logging: the entrypoint is always verbose and prints non-sensitive API output (token expiry, runner list counts). The script avoids printing secret values (tokens are masked).

Bringing the stack up

```bash
cp .env.example .env
# edit .env to set RUNNER_URL and GITHUB_TOKEN (or RUNNER_TOKEN for direct use)
docker compose up -d --build
```

Naming and running multiple runners

- The container name is derived from `RUNNER_NAME` (defaults to the hostname). Set a unique `RUNNER_NAME` in your `.env` for each runner you deploy to the same host.
- When running multiple runners on one host, isolate Compose resources using a different project name (or separate compose directories) so volumes and networks don't collide.

Examples

# Per-runner env file + project name
```bash
cp .env.example .env.runner1
# edit .env.runner1 and set RUNNER_NAME=runner-01 and GITHUB_TOKEN (or RUNNER_TOKEN)
docker compose -p runner1 --env-file .env.runner1 up -d --build

cp .env.example .env.runner2
# edit .env.runner2 and set RUNNER_NAME=runner-02 and GITHUB_TOKEN (or RUNNER_TOKEN)
docker compose -p runner2 --env-file .env.runner2 up -d --build
```

- Using `-p` (project) ensures Compose prefixes resource names (volumes, networks) and prevents collision between runner instances.
- Using `-p` (project) ensures Compose prefixes resource names (volumes, networks) and prevents collision between runner instances.

If you prefer a single-directory approach, ensure each runner uses a unique `RUNNER_NAME`. If you want to persist runner state (not ephemeral), you can add a per-runner volume name in `docker-compose.yml` (for example `actions-runner-${RUNNER_NAME}`) so state is stored separately per runner.
