# GitHub Actions Runner as a Docker container

This repository packages self-hosted GitHub Actions runners for Linux x64 and Windows x64. All you need is the name of the repo you are adding the runner to and your Personal Access Token (PAT). The runner is created and becomes active for the duration of container activity. Once the container is stopped, the runner is removed from your repo. No lingering offline runners. Easy and clean.

You can store your PAT as an environment variable for each stack separately or you can store it in a central credentials storage where it can be available to all your runners running on the same host. Even easier and even cleaner.

This image is a bootstrap pulling the latest Github runner image regardless of how recent the docker-github-runner image is by itself. The container will use the most up to date each time it is ran, even if it is just restarted. When restarting, it pulls a new runner image only if it actually is updated.

## Usage

My true purpose was to use this repository with Portainer. For usage with Portainer, see [Examples](#portainer-repository-stack).

This repository publishes platform-specific images on GitHub Container Registry:

- Linux: `ghcr.io/dam-pav/github-runner:latest`
- Windows Server 2022: `ghcr.io/dam-pav/github-runner:windows-ltsc2022`

The Linux and Windows images use separate tags because a Windows container must match a compatible Windows host kernel. The commands in the following sections use the Linux image unless stated otherwise.

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

### Windows runner

The Windows image runs Windows Server Core LTSC 2022, includes MinGit and the Docker CLI, and downloads the latest `win-x64` GitHub runner at container startup. The Windows Docker host must be compatible with the LTSC 2022 base image and must be configured to run Windows containers.

Use the Windows Compose file locally:

```powershell
Copy-Item .env.windows.example .env
# Edit .env and set REPO_URL, RUNNER_NAME, and GITHUB_TOKEN.
docker compose -f docker-compose.windows.yml up -d
```

The Compose definition pulls `ghcr.io/dam-pav/github-runner:windows-ltsc2022` when available. It also contains a build definition so a Windows Docker host can bootstrap the image directly from the repository before the registry image has been published.

To store the PAT on the Windows host instead of in Portainer, create `C:\ProgramData\github-runner\credentials`:

```powershell
New-Item -ItemType Directory -Force C:\ProgramData\github-runner | Out-Null
'GITHUB_TOKEN=ghp_xxx...' | Set-Content C:\ProgramData\github-runner\credentials
```

The Windows stack mounts the host Docker named pipe (`\\.\pipe\docker_engine`), allowing ordinary `docker` commands in workflows to address the Windows host daemon. It also starts a small cleanup sidecar before the runner. Windows containers do not receive a Linux-style termination signal, so the sidecar watches host Docker events and removes the GitHub registration when Portainer or Compose stops the runner. GitHub does not support container actions or service containers on Windows self-hosted runners; those workflow features require a Linux runner.

For nested Windows container workloads such as AL-Go and BcContainerHelper, the stack bind-mounts a runner-specific workspace at the same absolute path on both the host and runner container. With `RUNNER_NAME=bc-runner-01`, that path is `C:\actions-runner\_work\bc-runner-01`. It also shares `C:\ProgramData\BcContainerHelper` at the same path. This allows the host Docker daemon to resolve paths passed to it from inside the runner. A startup probe verifies both mounts before the runner registers with GitHub.

Create the host directories before deploying the stack:

```powershell
$runnerName = 'bc-runner-01'
New-Item -ItemType Directory -Force `
  "C:\actions-runner\_work\$runnerName", `
  'C:\ProgramData\BcContainerHelper' | Out-Null
```

Each runner must have a unique `RUNNER_NAME`; its work directory is fixed to `_work/<RUNNER_NAME>` and should not be overridden. Set `VALIDATE_NESTED_DOCKER_MOUNTS=false` only when deliberately running without nested Windows containers.

You need to provide the mandatory `RUNNER_NAME` and `REPO_URL`. `GITHUB_TOKEN` is required unless you provide a credentials file on the host at `/etc/github-runner/credentials`.
If that file exists and contains a `GITHUB_TOKEN` entry, the container will use it and the environment variable can be omitted.

On container start the image will request a registration token via the GitHub API (using `GITHUB_TOKEN`) and register the runner. When the container stops it will attempt to deregister the runner automatically, making the runner effectively ephemeral.

### Environment variables

| Name                 | Required | Description                                                                                                                                                                                                                                                                                                      |
| -------------------- | :------: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| REPO_URL             |   Yes   | URL of the organization or repository, e.g.`https://github.com/owner/repo`.                                                                                                                                                                                                                                    |
| GITHUB_TOKEN         |   Yes   | GitHub Personal Access Token (PAT) used to request a registration token via the API. For repository runners it needs `repo` scope; for organization runners it needs `admin:org` (or equivalent) scope. Can be provided as an environment variable or via a host credentials file (the file takes priority). |
| RUNNER_NAME          |   Yes   | Unique runner name for this instance; there is no default — you must set one per runner.                                                                                                                                                                                                                        |
| RUNNER_LABELS        |    No    | Comma-separated labels to add in addition to the fixed platform labels (`self-hosted,x64,linux` or `self-hosted,x64,windows`).                                                                                                                                                                                  |
| HOST_CRED_LOCATION   |    No    | Host location for the credentials directory (Linux default `/etc/github-runner`; Windows default `C:/ProgramData/github-runner`).                                                                                                                                                                              |
| WATCHTOWER           |    No    | Controls the `com.centurylinklabs.watchtower.enable` label; set to `true` to allow Watchtower detection (default `false`).                                                                                                                                                                                 |
| CUSTOM_LABEL         |    No    | Single additional label value (default `foo=bar`).                                                                                                                                                                                                                                                             |
| GH_API_RETRIES       |    No    | Number of attempts for GitHub API calls (default `6`).                                                                                                                                                                                                                                                         |
| GH_API_INITIAL_DELAY |    No    | Initial delay in seconds between retries (default `1`).                                                                                                                                                                                                                                                        |
| GH_API_BACKOFF_MULT  |    No    | Exponential backoff multiplier for retries (default `2`).                                                                                                                                                                                                                                                      |
| VALIDATE_NESTED_DOCKER_MOUNTS | No | Windows only. Runs a nested-container probe for the same-path workspace and BcContainerHelper mounts (default `true` in `docker-compose.windows.yml`). |

#### Notes

- The entrypoint determines the correct runner asset from the GitHub Releases API (`linux-x64` or `win-x64`) and downloads it automatically.
- The entrypoint stores a compact release record and only re-downloads the runner when that record changes, avoiding unnecessary downloads between container restarts. Stack rebuild destroys the record and always requires re-download.
- The entrypoint performs GitHub API calls (requesting registration tokens, listing and deleting runners) with retry and exponential backoff. You can tune behavior with these env vars. Defaults are shown in `.env.example`.
- Logging: the entrypoint is always verbose and prints non-sensitive API output (token expiry, runner list counts). The script avoids printing secret values (tokens are masked).

### Credentials file (optional)

You can store the `GITHUB_TOKEN` on the host instead of providing it in the environment. The container expects the host directory to be mounted at `/run/secrets` and reads `/run/secrets/credentials` (the provided `docker-compose.yml` mounts `/etc/github-runner` there).

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

For a Windows Docker endpoint, follow the same process with these changes:

- Set *Compose path* to `docker-compose.windows.yml`.
- Set `HOST_CRED_LOCATION=C:/ProgramData/github-runner` only if you want to override the default credentials directory.
- Ensure the Portainer endpoint is using Windows containers and is compatible with Windows Server Core LTSC 2022.
- Deploy the stack. The runner registers with the built-in labels `self-hosted`, `Windows`, and `X64`, plus any `RUNNER_LABELS` you supply.
- Keep both stack services running: `github-runner` executes jobs and `runner-cleanup` handles deregistration during a Portainer stack stop or redeploy.

The Windows image publishing workflow runs on `[self-hosted, windows, x64]`. The first Windows stack can build from the repository through Portainer; after it registers, that runner can publish subsequent `windows-ltsc2022` images to GHCR.
