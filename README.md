# GitHub Actions Runner as a Docker container

This image packages a self-hosted GitHub Actions runner for Linux x64.

Usage

This repository publishes a prebuilt image on GitHub Container Registry: `ghcr.io/dam-pav/github-runner:latest`.

Pull and run (single container):

```bash
docker pull ghcr.io/dam-pav/github-runner:latest
docker run --rm \
  -e REPO_URL=https://github.com/owner/repo \
  -e RUNNER_NAME=my-runner \
  -e GITHUB_TOKEN=ghp_xxx... \
  --name my-runner ghcr.io/dam-pav/github-runner:latest
```

Or use Docker Compose (pulls the image automatically):

```bash
cp .env.example .env
# edit .env to set REPO_URL, RUNNER_NAME and GITHUB_TOKEN
docker compose up -d
```


You need to provide the mandatory `RUNNER_NAME`, `REPO_URL` and `GITHUB_TOKEN`.

On container start the image will request a registration token via the GitHub API (using `GITHUB_TOKEN`) and register the runner. When the container stops it will attempt to deregister the runner automatically, making the runner effectively ephemeral.

Environment variables

- `REPO_URL` (required): URL of the organization or repository, e.g. `https://github.com/owner/repo`
- `GITHUB_TOKEN` (required): GitHub Personal Access Token (PAT) used to request a registration token via the API. For repository runners it needs `repo` scope; for organization runners it needs `admin:org` (or equivalent) scope.
- `RUNNER_NAME` (required): unique runner name for this instance; there is no default — you must set one per runner.
- `RUNNER_LABELS` (optional): comma-separated labels to add in addition to the fixed labels `self-hosted,x64,linux` that the container always advertises.

Notes

- The entrypoint determines the correct runner asset from the GitHub Releases API (selects the linux-x64 asset) and downloads it automatically.
- The entrypoint stores a compact release record and only re-downloads the runner when that record changes, avoiding unnecessary downloads between container restarts. Stack rebuild destroys the record and always requires re-download.

Retries and API configuration

- The entrypoint performs GitHub API calls (requesting registration tokens, listing and deleting runners) with retry and exponential backoff. You can tune behavior with these env vars (defaults shown in `.env.example`):
  - `GH_API_RETRIES`: number of attempts for API calls (default `6`)
  - `GH_API_INITIAL_DELAY`: initial delay in seconds between retries (default `1`)
  - `GH_API_BACKOFF_MULT`: exponential backoff multiplier (default `2`)
  - Logging: the entrypoint is always verbose and prints non-sensitive API output (token expiry, runner list counts). The script avoids printing secret values (tokens are masked).

Bringing the stack up

```bash
cp .env.example .env
# edit .env to set REPO_URL, RUNNER_NAME and GITHUB_TOKEN
docker compose up -d
```

Naming and running multiple runners

- `RUNNER_NAME` is required and must be unique for each runner you deploy to the same host. The container and GitHub registration use this name to identify the runner.
- When running multiple runners on one host, isolate Compose resources using a different project name (or separate compose directories) so volumes and networks don't collide.

Examples

# Per-runner env file + project name
```bash
cp .env.example .env.runner1
# edit .env.runner1 and set RUNNER_NAME=runner-01 and GITHUB_TOKEN
docker compose -p runner1 --env-file .env.runner1 up -d

cp .env.example .env.runner2
# edit .env.runner2 and set RUNNER_NAME=runner-02 and GITHUB_TOKEN
docker compose -p runner2 --env-file .env.runner2 up -d
```

- Using `-p` (project) ensures Compose prefixes resource names (volumes, networks) and prevents collision between runner instances.

If you prefer a single-directory approach, ensure each runner uses a unique `RUNNER_NAME`. If you want to persist runner state (not ephemeral), you can add a per-runner volume name in `docker-compose.yml` (for example `actions-runner-${RUNNER_NAME}`) so state is stored separately per runner.

# Portainer: Repository stack

In Portainer, go to *Stacks → Add stack*.

Select *Build method*: `Repository`. You can always *Detach from git* later if you want to edit the compose file.

Set *Repository URL* to `https://github.com/dam-pav/docker-github-runner.git`.

The default *Repository reference* (`refs/heads/main`) should be fine.

The deafult *Compose path* (`docker-compose.yml`) should also be fine.

Choose a stack name (e.g. `github-runner-01`).

In *Environment variables*, add the required variables:
  - `REPO_URL=https://github.com/owner/repo`
  - `RUNNER_NAME=unique-runner-name` (required)
  - `GITHUB_TOKEN=ghp_xxx...` (required)
  - `RUNNER_LABELS=your_specific_label` (optional — adds to fixed labels)

Deploy the stack. Portainer will pull `ghcr.io/dam-pav/github-runner:latest` by default. The stack restart policy is set to `unless-stopped` to keep the runner running.

For multiple runners, create separate stacks (or use different stack names) and ensure each uses a unique `RUNNER_NAME`.
