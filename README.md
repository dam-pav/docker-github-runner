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
- `CONTAINER_NAME` (optional): container name used by `docker compose`; set a unique name per runner when running multiple on the same host

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
