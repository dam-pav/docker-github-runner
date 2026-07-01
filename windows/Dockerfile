# escape=`

ARG WINDOWS_VERSION=ltsc2022
FROM mcr.microsoft.com/windows/servercore:${WINDOWS_VERSION}

SHELL ["powershell.exe", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG GIT_VERSION=2.54.0
ARG GIT_WINDOWS_PATCH=1
ARG GIT_LFS_VERSION=3.7.1
ARG GIT_LFS_SHA256=8683CDC3D6C029B49393DCEBBAA6265BD6EFD9ABDCF837BE855B4CD42E5E80B6
ARG DOCKER_VERSION=29.6.1
ARG POWERSHELL_VERSION=7.4.16
ARG POWERSHELL_SHA256=4799A560B7C312FBC1AE5209724A5CDDD3F1E626257685AF43B6BB57112758E3

RUN New-Item -ItemType Directory -Force C:\actions-runner, C:\tools | Out-Null; `
    Invoke-WebRequest -UseBasicParsing `
      -Uri "https://github.com/git-for-windows/git/releases/download/v${env:GIT_VERSION}.windows.${env:GIT_WINDOWS_PATCH}/MinGit-${env:GIT_VERSION}-64-bit.zip" `
      -OutFile C:\tools\mingit.zip; `
    Expand-Archive C:\tools\mingit.zip -DestinationPath C:\MinGit; `
    Remove-Item C:\tools\mingit.zip; `
    Invoke-WebRequest -UseBasicParsing `
      -Uri "https://github.com/git-lfs/git-lfs/releases/download/v${env:GIT_LFS_VERSION}/git-lfs-windows-amd64-v${env:GIT_LFS_VERSION}.zip" `
      -OutFile C:\tools\git-lfs.zip; `
    if ((Get-FileHash C:\tools\git-lfs.zip -Algorithm SHA256).Hash -ne $env:GIT_LFS_SHA256) { `
      throw 'Git LFS archive checksum verification failed' `
    }; `
    Expand-Archive C:\tools\git-lfs.zip -DestinationPath C:\tools\git-lfs-package; `
    $gitLfs = Get-ChildItem C:\tools\git-lfs-package -Filter git-lfs.exe -Recurse | Select-Object -First 1; `
    if ($null -eq $gitLfs) { throw 'Git LFS executable was not found in the archive' }; `
    Move-Item $gitLfs.FullName C:\tools\git-lfs.exe; `
    Remove-Item C:\tools\git-lfs-package -Recurse -Force; `
    Remove-Item C:\tools\git-lfs.zip; `
    Invoke-WebRequest -UseBasicParsing `
      -Uri "https://download.docker.com/win/static/stable/x86_64/docker-${env:DOCKER_VERSION}.zip" `
      -OutFile C:\tools\docker.zip; `
    Expand-Archive C:\tools\docker.zip -DestinationPath C:\tools; `
    Move-Item C:\tools\docker\docker.exe C:\tools\docker.exe; `
    Remove-Item C:\tools\docker -Recurse -Force; `
    Remove-Item C:\tools\docker.zip; `
    Invoke-WebRequest -UseBasicParsing `
      -Uri "https://github.com/PowerShell/PowerShell/releases/download/v${env:POWERSHELL_VERSION}/PowerShell-${env:POWERSHELL_VERSION}-win-x64.zip" `
      -OutFile C:\tools\powershell.zip; `
    if ((Get-FileHash C:\tools\powershell.zip -Algorithm SHA256).Hash -ne $env:POWERSHELL_SHA256) { `
      throw 'PowerShell archive checksum verification failed' `
    }; `
    Expand-Archive C:\tools\powershell.zip -DestinationPath C:\PowerShell; `
    Remove-Item C:\tools\powershell.zip

ENV PATH="C:\actions-runner;C:\MinGit\cmd;C:\tools;C:\PowerShell;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32;C:\Windows"

WORKDIR C:\actions-runner

COPY entrypoint.ps1 C:\entrypoint.ps1
COPY cleanup-monitor.ps1 C:\cleanup-monitor.ps1

ENTRYPOINT ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\entrypoint.ps1"]
