# Use the Windows runner with AL-Go

This guide covers the additional host and repository configuration required to run Microsoft AL-Go build and test jobs on the Windows self-hosted runner from this repository.

AL-Go supports self-hosted runners through repository settings. Do not edit generated AL-Go workflow files to replace `windows-latest` manually.

## Scope and support boundary

- Use a Windows Server host compatible with Windows Server Core LTSC 2022.
- Use Docker Engine configured for Windows containers. Docker Desktop is not an actively supported target for this repository.
- Treat the runner as trusted infrastructure. Workflow code can access the host Docker daemon through the mounted named pipe.
- Register the runner with the AL-Go target repository, or with an organization that grants that repository access to the runner.
- The current runner image provides PowerShell 7 (`pwsh`), Windows PowerShell 5.1, MinGit, Git LFS, and the Docker CLI. PowerShell 7 is required because AL-Go actions can invoke `pwsh` internally even when `githubRunnerShell` is set to `powershell`.

Review Microsoft's current [AL-Go self-hosted runner prerequisites](https://github.com/microsoft/AL-Go/blob/main/Scenarios/SelfHostedGitHubRunner.md) before treating a runner as production-ready. Additional AL-Go scenarios may require tools beyond the bootstrap image's guaranteed toolset.

## 1. Prepare the Windows Docker host

Choose a unique runner name and create the bind-mount source directories before deploying the stack:

```powershell
$runnerName = 'al-go-windows-01'

New-Item -ItemType Directory -Force `
  "C:\actions-runner\_work\$runnerName", `
  'C:\ProgramData\BcContainerHelper', `
  'C:\ProgramData\github-runner' | Out-Null
```

The runner workspace and `BcContainerHelper` directory are mounted at identical host and container paths. AL-Go and `BcContainerHelper` pass runner paths to the host Docker daemon when creating nested Windows containers; the daemon must be able to resolve those paths on the host.

Each runner on the same host must use a unique `RUNNER_NAME`. Do not override `RUNNER_WORKDIR`; the Windows Compose definition derives it from the runner name.

## 2. Deploy the runner stack

For a Portainer Git stack, use:

- Repository URL: `https://github.com/dam-pav/docker-github-runner.git`
- Compose path: `windows-compose.yml`
- Repository reference: the intended release branch or tag

Configure these stack environment variables:

```text
REPO_URL=https://github.com/owner/al-go-repository
RUNNER_NAME=al-go-windows-01
RUNNER_LABELS=al-go
GITHUB_TOKEN=<token with runner-registration access>
WINDOWS_VERSION=ltsc2022
VALIDATE_NESTED_DOCKER_MOUNTS=true
```

`REPO_URL` must identify the repository that contains the AL-Go workflows unless the runner is registered at organization scope. A runner registered with a different repository is not visible to the AL-Go target repository.

Keep `VALIDATE_NESTED_DOCKER_MOUNTS=true`. Before registering with GitHub, the entrypoint verifies that a nested Windows container can read both same-path host mounts through the Docker named pipe.

Successful startup logs include messages equivalent to:

```text
Docker CLI can reach the host daemon through the named pipe
Nested Docker mount validation succeeded
Runner successfully added
Listening for Jobs
```

## 3. Verify runner scope and labels

In the AL-Go target repository, open **Settings → Actions → Runners**. Confirm that the runner is online and exposes all of these labels:

```text
self-hosted
Windows
X64
al-go
```

GitHub requires every label in a workflow's `runs-on` selection to match. A runner can be online and still leave a job queued when its repository scope or labels do not match.

## 4. Configure the AL-Go target repository

Open `.github/AL-Go-Settings.json` in the target repository and add these properties to the existing JSON object:

```json
{
  "githubRunner": "self-hosted,Windows,X64,al-go",
  "githubRunnerShell": "powershell",
  "cacheImageName": ""
}
```

Merge these properties with the repository's existing settings; do not replace settings such as `type`, `templateUrl`, or schedules.

`githubRunner` controls AL-Go build and test jobs. `githubRunnerShell` selects the shell used by those jobs. The general `runs-on` setting controls non-build AL-Go jobs and should remain unchanged unless there is a separate, deliberate requirement to move management jobs to self-hosted infrastructure.

Keep `githubRunnerShell` set to `powershell` for this Windows Server Core image. PowerShell 7 remains installed and available on `PATH` because AL-Go invokes `pwsh` internally, but AL-Go v9 telemetry loads a .NET Framework Application Insights assembly that is compatible with Windows PowerShell 5.1.

Keep `cacheImageName` set to an empty string for this containerized runner. The default value (`my`) enables Docker image-cache maintenance that inspects every image exposed by the shared host Docker daemon and can fail in `Flush-ContainerHelperCache` when an unrelated image does not contain the metadata expected by BcContainerHelper. An empty value does not disable Docker or prevent AL-Go from creating temporary Business Central containers for test execution; it only disables reusable build-image caching, so container-based builds may take longer. Place `"cacheImageName": ""` in the `ALGoOrgSettings` organization variable to apply it centrally, or override it in each repository as shown above.

No generated workflow edit is required. AL-Go reads `githubRunner` during workflow initialization and passes the resulting label list to its reusable build workflow. See the official [AL-Go settings reference](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md#githubrunner).

## 5. Validate with a controlled workflow run

1. Commit the settings change on a branch in the target repository.
2. Open a pull request or manually dispatch an AL-Go build workflow.
3. Confirm that the initialization and management jobs use their normal GitHub-hosted runners.
4. Confirm that the AL-Go `Build` job is assigned to the Windows self-hosted runner.
5. Inspect the runner and workflow logs for Docker, container creation, package-cache, or assembly-probing failures.

The first AL-Go build is the compatibility test for the runner image. A runner being online only proves registration and label routing; it does not prove that every tool required by the selected AL-Go scenario is installed.

## Troubleshooting

### Build job remains queued

- Confirm the runner is registered with the target repository or an authorized organization.
- Compare the GitHub-visible labels with `githubRunner` exactly.
- Confirm the runner is online and not already executing another job.

### Stack deployment reports a missing bind source

Create all host directories from step 1 before redeploying. Windows Docker does not create these Portainer bind sources automatically.

### Nested mount validation fails

- Confirm Docker Engine is running Windows containers.
- Confirm the host workspace path contains the exact `RUNNER_NAME` configured in Portainer.
- Confirm the host and container paths in `windows-compose.yml` are identical.
- Confirm `C:\ProgramData\BcContainerHelper` exists and is accessible to Docker.

### `pwsh` is not found

Rebuild or pull the current Windows runner image and recreate the runner container. Changing `githubRunnerShell` to `powershell` is insufficient because AL-Go actions can invoke `pwsh` internally.

### `Flush-ContainerHelperCache` reports a missing `Env` property

Confirm that the effective AL-Go settings contain `"cacheImageName": ""`. This prevents BcContainerHelper from performing build-image cache maintenance against unrelated images exposed by the shared host Docker daemon.

### AL-Go reports missing tools or modules

Compare the runner image with Microsoft's current self-hosted prerequisite list. Install or add missing prerequisites to the runner image deliberately; do not work around missing runner dependencies by editing generated AL-Go workflows.

## Security consideration

Only route trusted workflow code to this runner. The runner can control the host Docker daemon, and self-hosted jobs are not isolated from persistent host resources to the same degree as GitHub-hosted runners. Review branch protection, fork pull-request policy, workflow permissions, and who can modify workflow files before enabling the runner for a repository.
