# Docker Build System

Reproducible Android APK builds using Docker, matching our CI environment.

## Setup

Install Docker

```
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker "$USER"
exec sudo su -l $USER
```

## Quick Start

Build a debug APK:
```bash
./docker/build-apk.sh debug
```

## Build Options

- `CLEAN=1`: Wipe all build caches (Flutter, Rust, Gradle)
- `REBUILD_IMAGE=1`: Rebuild the Docker image

Example:
```bash
CLEAN=1 REBUILD_IMAGE=1 ./docker/build-apk.sh debug
```
