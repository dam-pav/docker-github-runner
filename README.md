# GitHub Actions Runner as a Docker container

This image packages a self-hosted GitHub Actions runner for Linux x64. All you need is the name of the repo you are adding the runner to and your Personal Access Token (PAT). The runner is created and becomes active for the duration of container activity. Once the container is stopped, the runner is removed from your repo. No lingering offline runners. Easy and clean.

You can store your PAT as an environment variable for each stack separately or you can store it in a central credentials storage where it can be available to all your runners running on the same host. Even easier and even cleaner.

This image is a bootstrap pulling the latest Github runner image regardless of how recent the docker-github-runner image is by itself. The container will use the most up to date each time it is ran, even if it is just restarted. When restarting, it pulls a new runner image only if it actually is updated.

## Usage

My true purpose was to use this repository with Portainer. For usage with Portainer, see [Examples](#portainer-repository-stack).

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

Or use Docker Compose:

```bash
# create a suitable folder
mkdir my-repo-runner
cd my-repo-runner
# download docker-compose.yml and .env.example from this repository
curl -LO https://raw.githubusercontent.com/dam-pav/docker-github-runner/main/docker-compose.yml \
     -LO https://raw.githubusercontent.com/dam-pav/docker-github-runner/main/.env.example
cp .env.example .env
# edit .env to set REPO_URL, RUNNER_NAME and GITHUB_TOKEN
docker compose up -d
```

You need to provide the mandatory `RUNNER_NAME` and `REPO_URL`. `GITHUB_TOKEN` is required unless you provide a credentials file on the host at `/etc/github-runner/credentials`.
If that file exists and contains a `GITHUB_TOKEN` entry, the container will use it and the environment variable can be omitted.

On container start the image will request a registration token via the GitHub API (using `GITHUB_TOKEN`) and register the runner. When the container stops it will attempt to deregister the runner automatically, making the runner effectively ephemeral.

### Environment variables

| :-------------------- | :---: | :--- |
| Name                 | Required | Description |
| -------------------- | :---: | --- |
| REPO_URL             |   Yes | URL of the organization or repository, e.g.`https://github.com/owner/repo`. |
| GITHUB_TOKEN         |   Yes | GitHub Personal Access Token (PAT) used to request a registration token via the API. For repository runners it needs `repo` scope; for organization runners it needs `admin:org` (or equivalent) scope. Can be provided as an environment variable or via a host credentials file (the file takes priority). |
| RUNNER_NAME          |   Yes | Unique runner name for this instance; there is no default — you must set one per runner. |
| RUNNER_LABELS        |    No | Comma-separated labels to add in addition to the fixed labels `self-hosted,x64,linux`. |
| HOST_CRED_LOCATION   |    No | Host location for the credentials file (default `/etc/github-runner`). |
| WATCHTOWER           |    No | Controls the `com.centurylinklabs.watchtower.enable` label; set to `true` to allow Watchtower detection (default `false`). |
| CUSTOM_LABEL         |    No | Single additional label value (default `foo=bar`). |
| GH_API_RETRIES       |    No | Number of attempts for GitHub API calls (default `6`). |
| GH_API_INITIAL_DELAY |    No | Initial delay in seconds between retries (default `1`). |
| GH_API_BACKOFF_MULT  |    No | Exponential backoff multiplier for retries (default `2`). |

#### Notes

- The entrypoint determines the correct runner asset from the GitHub Releases API (selects the linux-x64 asset) and downloads it automatically.
- The entrypoint stores a compact release record and only re-downloads the runner when that record changes, avoiding unnecessary downloads between container restarts. Stack rebuild destroys the record and always requires re-download.
- The entrypoint performs GitHub API calls (requesting registration tokens, listing and deleting runners) with retry and exponential backoff. You can tune behavior with these env vars. Defaults are shown in `.env.example`.
- Logging: the entrypoint is always verbose and prints non-sensitive API output (token expiry, runner list counts). The script avoids printing secret values (tokens are masked).

### Credentials file (optional)

You can store the `GITHUB_TOKEN` on the host instead of providing it in the environment. The container expects the file to be mounted at `/run/secrets/github-runner` (the `docker-compose.yml` provided binds `/etc/github-runner/credentials` to that path).

```bash
# initialize parameters (provide your own PAT and modify LOC if necessary)
PAT=ghp_*************************
LOC=/etc/github-runner
# ensure parent directory exists
sudo mkdir -p $LOC
# create the credentials file
printf '%s\n' "$PAT" | sudo tee "$LOC/credentials" >/dev/null
# restrict permissions
sudo chmod 600 $LOC/credentials
sudo chown root:root $LOC/credentials
# allow traversal
sudo chmod 755 $LOC
```

When the credentials file is present and contains a `GITHUB_TOKEN` entry, its value takes priority over any `GITHUB_TOKEN` environment variable and the env var can be left empty or omitted entirely.

While `/etc/github-runner` is the default host location, you can specify a different location with the environment variable `HOST_CRED_LOCATION`. Adjust LOC in the above script to match.

### Naming and running multiple runners

- `RUNNER_NAME` is required and must be unique for each runner you deploy to the same host. The container and GitHub registration use this name to identify the runner.
- When running multiple runners on one host, isolate Compose resources using a different project name (or separate compose directories) so volumes and networks don't collide.

### Docker socket and running Docker-in-Docker workflows

- The image supports mounting the host Docker socket so workflow jobs can use `docker`.
- Ensure you mount the socket when starting the container: `-v /var/run/docker.sock:/var/run/docker.sock` (this is already present in `docker-compose.yml`).
- On container start the entrypoint will (when run as root) detect the socket's group id, create a group in the container with that gid and add the `runner` user to it so the `runner` user can access the socket without running the runner as root.
- If you still see permission errors, run the container with elevated privileges (e.g. `--privileged`) or check host socket permissions and the uid/gid mapping of `/var/run/docker.sock` on the host.

## Examples

### Per-runner env file + project name

```bash
cp .env.example .env.runner1
# edit .env.runner1 and set RUNNER_NAME=runner-01 and GITHUB_TOKEN
docker compose -p runner1 --env-file .env.runner1 up -d

cp .env.example .env.runner2
# edit .env.runner2 and set RUNNER_NAME=runner-02 and GITHUB_TOKEN
docker compose -p runner2 --env-file .env.runner2 up -d
```

Using `-p` (project) ensures Compose prefixes resource names (volumes, networks) and prevents collision between runner instances.

If you prefer a single-directory approach, ensure each runner uses a unique `RUNNER_NAME`. If you want to persist runner state (not ephemeral), you can add a per-runner volume name in `docker-compose.yml` (for example `actions-runner-${RUNNER_NAME}`) so state is stored separately per runner.

### Portainer: Repository stack

- In Portainer, go to *Stacks → Add stack*.
- Select *Build method*: `Repository`. You can always *Detach from git* later if you want to edit the compose file.
- Set *Repository URL* to `https://github.com/dam-pav/docker-github-runner.git`.
- The default *Repository reference* (`refs/heads/main`) should be fine.
- The deafult *Compose path* (`docker-compose.yml`) should also be fine.
- Choose a stack name (e.g. `github-runner-01`).
- In *Environment variables*, add the required variables:

  - `REPO_URL=https://github.com/owner/repo`
  - `RUNNER_NAME=unique-runner-name` (required)
  - `GITHUB_TOKEN=ghp_xxx...` (required unless you provide a host credentials file mounted to `/run/secrets/github-runner`)
  - `RUNNER_LABELS=your_specific_label` (optional — adds to fixed labels)
- Deploy the stack. Portainer will pull `ghcr.io/dam-pav/github-runner:latest` by default. The stack restart policy is set to `unless-stopped` to keep the runner running.
- For multiple runners, create separate stacks and ensure each uses a unique `RUNNER_NAME`.
