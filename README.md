# AutoDelete Discord bot, hardened image

[![build](https://github.com/outpoints/docker-autodelete-discord/actions/workflows/build.yml/badge.svg)](https://github.com/outpoints/docker-autodelete-discord/actions/workflows/build.yml) [![vulncheck](https://github.com/outpoints/docker-autodelete-discord/actions/workflows/vulncheck.yml/badge.svg)](https://github.com/outpoints/docker-autodelete-discord/actions/workflows/vulncheck.yml)

Docker image for [AutoDelete](https://github.com/riking/AutoDelete), a Discord bot that deletes messages in a channel on a rolling basis. Forked from [ksurl/docker-autodelete-discord](https://github.com/ksurl/docker-autodelete-discord) and rebuilt so the code that runs is fixed when the image is built.

```
ghcr.io/outpoints/autodelete-discord
```

Platforms: `linux/amd64`, `linux/arm64`, `linux/arm/v7`.

## What's different

| | ksurl/autodelete-discord 1.5.1 | This image |
| --- | --- | --- |
| Bot code | Pulled from upstream `master` and recompiled on every container start | Compiled once from pinned upstream commit `8cd5bdc` |
| Base images | Tag only | Pinned by digest, bumped through Dependabot PRs |
| Runtime contents | Alpine, Go toolchain and git, about 460 MB | distroless/static and the bot binary, about 16 MB |
| User | root | UID/GID 65532 |
| Reachable vulnerabilities (govulncheck) | 1 | 0 |
| Publishing | Personal access tokens | Workflow `GITHUB_TOKEN`, signed build provenance |

The only changes to the upstream source are two lines in its `go.mod`. They're explained in the [Dockerfile](Dockerfile):

- `gorilla/websocket` goes from v1.5.0 to v1.5.3 to fix [GO-2026-6278](https://pkg.go.dev/vuln/GO-2026-6278).
- `godebug default=go1.27` makes the Go runtime use current security defaults. Upstream's `go 1.13` line otherwise keeps older ones, such as accepting SHA-1 TLS signatures.

## Usage

```yaml
services:
  autodelete:
    image: ghcr.io/outpoints/autodelete-discord:latest
    container_name: autodelete
    ports:
      - 2202:2202
    volumes:
      - ./config.yml:/app/config.yml:ro
      - ./data:/app/data
    restart: always
    # Optional hardening. The image works with or without these lines.
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
```

| Mount | Purpose |
| --- | --- |
| `/app/config.yml` | Bot config. See [`config.example.yml`](https://github.com/riking/AutoDelete/blob/master/config.example.yml) upstream. Can be read-only. |
| `/app/data` | Per-channel settings. Must be writable by UID 65532. |

The bot's OAuth pages listen on `http.listen` from `config.yml`. The upstream example uses `localhost:2202`, which isn't reachable through the published port. Set it to `0.0.0.0:2202` only if you use those pages. Otherwise you can drop the `ports` section.

## Switching from ksurl/autodelete-discord

The old image ran as root, so files it created in `./data` belong to root. This image runs as UID 65532 and can't write them until you change the owner once.

1. In the folder with your `docker-compose.yml`:

   ```sh
   sudo chown -R 65532:65532 ./data
   sudo chown 65532:65532 ./config.yml
   sudo chmod 600 ./config.yml
   ```

   `config.yml` holds the bot token, so `600` keeps other users on the host from reading it. If the bot can't read the file, it prints `Please copy config.yml.example to config.yml` and exits.

2. Change the `image:` line to `ghcr.io/outpoints/autodelete-discord:latest`, or pin a version like `:2.0.0`. Optionally add `:ro` to the config mount and the hardening lines above.

3. Pull and restart:

   ```sh
   docker compose pull autodelete
   docker compose up -d autodelete
   docker compose logs -f autodelete
   ```

To roll back, change the `image:` line back. The old image runs as root, so it can still use the files after the ownership change.

## Verifying an image

Every image pushed from this repository has a signed build provenance attestation that links it to the workflow run and commit that built it:

```sh
gh attestation verify oci://ghcr.io/outpoints/autodelete-discord:latest --owner outpoints
```

The image also carries the upstream commit it was built from:

```sh
docker inspect ghcr.io/outpoints/autodelete-discord:latest \
  --format '{{ index .Config.Labels "io.github.riking.autodelete.commit" }}'
```

## Updates

- **Base images and GitHub Actions.** Dependabot opens a PR each week when the pinned `golang` or `distroless` digests or the actions change. The PR build runs the smoke test. Merging to `main` publishes a new `:latest`.
- **Bot code.** Review the upstream commits, then change `AUTODELETE_COMMIT` in the Dockerfile to the new full SHA. Check whether the `go.mod` changes are still needed.
- **Releases.** Push a tag like `v2.0.1` to publish `:2.0.1` and `:2.0`.
- **Vulnerabilities.** The `vulncheck` workflow runs govulncheck against the exact source the image is built from on every push and every Monday. Run it locally with `docker build --target vulncheck .`.

## Known scanner findings

Image scanners such as Grype report 4 advisories in `golang.org/x/net` (2 High, 2 Medium). govulncheck confirms the bot never calls the affected code. The fixed version requires raising upstream's `go.mod` to Go 1.25 and upgrading dozens of other modules. That changes language behavior in an old codebase with no tests, so it's left as is.

## License

MIT, same as the original repository.
