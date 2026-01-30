# GitHub Actions Runner (container)

This image packages a self-hosted GitHub Actions runner for Linux x64.

Build

```bash
docker build -t github-runner:2.331.0 .
```

Run (register and start the runner)

Provide `RUNNER_URL` and `RUNNER_TOKEN` environment variables. Example for a repository runner:

```bash
docker run --rm -e RUNNER_URL=https://github.com/dam-pav/acme-worker \
  -e RUNNER_TOKEN=ALCGQ5T5ODMIEMDFDUU6XALJPOR5W \
  --name my-runner github-runner:2.331.0
```

On first container start the image will run `./config.sh` (unattended) to register the runner. Subsequent starts will skip configuration and run `./run.sh`.

Environment variables

- `RUNNER_URL` (required on first run): URL of the organization or repository, e.g. `https://github.com/owner/repo`
- `RUNNER_TOKEN` (required on first run): registration token from GitHub
- `RUNNER_NAME` (optional): runner name; defaults to container hostname
- `RUNNER_WORKDIR` (optional): work directory inside the runner; defaults to `_work`
- `RUNNER_LABELS` (optional): comma-separated labels

Notes

- You are responsible for generating a valid `RUNNER_TOKEN` (GitHub site > Settings > Actions > Runners > New self-hosted runner).
- The image downloads the runner release defined by `RUNNER_VERSION` in the `Dockerfile`.

Persistence

- The provided `docker-compose.yml` mounts a named volume `runner-data` at `/actions-runner` to persist configuration and runner state across container recreation.

If you need to recreate the image or container, the runner will remain registered as long as the `runner-data` volume is preserved. To bring the stack up:

```bash
cp .env.example .env
# edit .env to set RUNNER_URL and RUNNER_TOKEN
docker compose up -d
```

To remove the container but keep data:

```bash
docker compose down
```

To remove data as well:

```bash
docker compose down -v
```

Naming and running multiple runners

- The container name is derived from `RUNNER_NAME` (defaults to the hostname). Set a unique `RUNNER_NAME` in your `.env` for each runner you deploy to the same host.
- When running multiple runners on one host, isolate Compose resources using a different project name (or separate compose directories) so volumes and networks don't collide.

Examples

# Per-runner env file + project name
```bash
cp .env.example .env.runner1
# edit .env.runner1 and set RUNNER_NAME=runner-01 and RUNNER_TOKEN
docker compose -p runner1 --env-file .env.runner1 up -d --build

cp .env.example .env.runner2
# edit .env.runner2 and set RUNNER_NAME=runner-02 and RUNNER_TOKEN
docker compose -p runner2 --env-file .env.runner2 up -d --build
```

- Using `-p` (project) ensures Compose prefixes resource names (volumes, networks) and prevents collision between runner instances.

- If you prefer a single directory approach, ensure each runner uses a unique `RUNNER_NAME` and adjust the volume name in `docker-compose.yml` (for example `runner-data-${RUNNER_NAME}`) so state is stored separately per runner.
