# ntfy behind Traefik

[ntfy](https://ntfy.sh) is a push notification server. You send a message with an
HTTP request, and phones, browsers and scripts that subscribe to the topic get it.
This repo runs a private ntfy server with Docker Compose behind
[Traefik](https://github.com/ali-avani/traefik-docker-kubernates), which provides
HTTPS. Install Traefik first.

## Requirements

- Docker with Docker Compose v2
- Traefik on the same server (Docker provider, host network)
- A DNS record for the ntfy domain pointing at this server (Let's Encrypt HTTP challenge)

## Install

```bash
bash ./install.sh
```

It asks for the domain, the ntfy version, and the admin user and password. Then it
writes `.env`, starts ntfy and creates the admin user. The admin user is created only
on a new install, when `data/user.db` does not exist.

```bash
bash ./install.sh --yes          # never prompt
bash ./install.sh --no-start     # write the configuration only
bash ./install.sh --update-env   # rebuild .env from .env.sample, keep your values
```

Values are read from the environment or `.env` first. The password is never stored, so
pass it in the environment for an unattended install:

```bash
NTFY_DOMAIN=ntfy.example.com ADMIN_USER=admin ADMIN_PASSWORD='change-me-please' \
  bash ./install.sh --yes
```

| Variable | Description |
| -------- | ----------- |
| `NTFY_DOMAIN` | Domain of ntfy |
| `NTFY_VERSION` | Image tag (default `v2.37.2`) |
| `NTFY_IMAGE` | Image repository, for a mirror (default `binwiederhier/ntfy`) |
| `NTFY_CACHE_DURATION` | How long messages stay for clients that reconnect (default `24h`) |
| `NTFY_AUTH_DEFAULT_ACCESS` | Access without a login (default `deny-all`) |
| `NTFY_LOG_LEVEL` | `TRACE`, `DEBUG`, `INFO`, `WARN` or `ERROR` (default `INFO`) |
| `ADMIN_USER` | Admin user for a new install (default `admin`) |
| `COMPOSE_FILE` | Set by the installer |

To upgrade ntfy, change `NTFY_VERSION` and run `docker compose up -d`. Read the
[release notes](https://docs.ntfy.sh/releases/) first.

## How it works

- ntfy reads its settings from `NTFY_*` environment variables in `docker-compose.yaml`.
  There is no `server.yml`, so an override file can add any other
  [setting](https://docs.ntfy.sh/config/#config-options).
- `data/` holds `user.db` (users, access rules and tokens) and `cache.db` (messages).
- Without a login, every topic is closed (`deny-all`). Give each user or script access
  to the topics it needs.
- HTTPS comes from Traefik's `le` certificate resolver on the `websecure` entry point.

## Users and tokens

Run the `ntfy` command in the container. Commands that set a password ask for it.

```bash
docker exec -it ntfy ntfy user add --role=admin ali        # admin: all topics
docker exec -it ntfy ntfy user add alerts                  # normal user
docker exec ntfy ntfy access alerts server-alerts rw       # read-write on one topic
docker exec ntfy ntfy user list
```

A script that only sends messages needs a write-only user and a token:

```bash
docker exec -it ntfy ntfy user add backup-bot
docker exec ntfy ntfy access backup-bot backups wo
docker exec ntfy ntfy token add backup-bot
```

Send with the token:

```bash
curl -H "Authorization: Bearer tk_..." -d "Backup done" https://ntfy.example.com/backups
```

## Phone

1. Install the ntfy app (Google Play, F-Droid or the App Store).
2. In Settings > Manage users, add your user for `https://<NTFY_DOMAIN>`.
3. Subscribe to a topic. Turn on "Use another server" and enter the same URL.

On Android, the app keeps a connection open to your server, because only `ntfy.sh` can
use Firebase. Turn off battery optimization for the app. On iOS, set
`NTFY_UPSTREAM_BASE_URL` (see `examples/docker-compose.override.yaml`).

## Per-server changes

Copy `examples/docker-compose.override.yaml` to `docker-compose.override.yaml`
(git-ignored), uncomment what you need and run `bash ./install.sh --update-env`.
Use it for attachments, iOS push, a time zone or `extra_hosts`.

## Backups

Back up `data/user.db`. It holds the users, access rules and tokens. `cache.db` holds
only recent messages. Stop ntfy first, or use `sqlite3 data/user.db ".backup user.db.bak"`.

## Files

```
install.sh                      installer
docker-compose.yaml             ntfy service and Traefik labels
docker-compose.override.yaml    your changes (not committed)
.env.sample                     variables
data/                           users, tokens and messages (not committed)
examples/                       override sample
```

## Troubleshooting

- Logs: `docker compose logs -f ntfy`.
- Health: `curl https://<NTFY_DOMAIN>/v1/health` returns `{"healthy":true}`.
- 403 on publish or subscribe: the user or token has no access to the topic. Check with
  `docker exec ntfy ntfy user list`.
- The phone app shows `SocketTimeoutException: timeout`: the app got no data on its
  open connection, not even the keepalive. Test the stream from another network with
  `curl -u <user> https://<NTFY_DOMAIN>/<topic>/json`. It prints a keepalive line every 45
  seconds. If curl works, check the phone's network path, for example a VPN or proxy app.

## Stopping

```bash
docker compose down        # keeps data/
```
