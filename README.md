# UnderstandTech — AI in a Box

Deploy the UnderstandTech platform on NVIDIA DGX Spark systems using Docker Compose.

## Architecture

<img width="1436" height="1298" alt="image" src="https://github.com/user-attachments/assets/75dc1a86-391a-455b-84cf-711538ea3b47" />


## What's in This Repo

| File | Purpose |
|---|---|
| `compose.yaml` | Docker Compose stack — all services, networks, volumes |
| `Caddyfile` | Reverse proxy config — routes traffic to frontend, API, and REST API |
| `env.example` | Template for `.env` — credentials, API keys, model config |
| `setup-autostart.sh` | Installs a systemd service so the stack starts on boot |
| `ut-logs.sh` | Automated daily log archival with compression and retention |

## Quick Start

```bash
# 1. Clone and configure
git clone https://dgx-access:<TOKEN>@github.com/understand-tech/ai-in-a-box.git ~/understand-tech
cd ~/understand-tech
cp env.example .env
chmod 600 .env
# Edit .env — set MONGODB_USERNAME, MONGODB_PASSWORD at minimum

# 2. Pull images and start
docker compose pull
docker compose up -d

# 3. Verify
docker compose ps
```

Access the platform at `https://understand.local` once all services are healthy.

## Services

| Service | Container | Port | Description |
|---|---|---|---|
| Caddy | `ut-caddy` | 80, 443 | HTTPS reverse proxy with internal TLS |
| Frontend | `ut-frontend` | 80 (internal) | React web application |
| API | `ut-api` | 8501 (internal) | Main backend API (FastAPI) |
| API-Customer | `ut-api-customer` | 8501 (internal) | Partner (REST) API |
| Workers | `understandtech-workers-*` | — | RQ background job processing |
| Workers-Customer | `understandtech-workers-customer-*` | — | Partner background job processing |
| LLM | `ut-llm` | 8000 (internal) | GPU-accelerated model inference |
| MongoDB | `ut-mongodb` | 27017 (localhost) | Document database |
| Redis | `ut-redis` | 6379 (internal) | Task queue and cache |
| MongoDB Backup | `ut-mongodb-backup` | — | Automated daily backups |

## Networks

The stack uses two isolated Docker bridge networks:

- **`ut-frontend-network`** — Caddy, Frontend, API, API-Customer (services that need to be reachable from the reverse proxy)
- **`ut-backend-network`** (internal, no external access) — API, Workers, LLM, Redis, MongoDB, Backup, LLM

## Volumes

| Volume | Purpose |
|---|---|
| `ut-caddy-data` | Caddy TLS certificates and state |
| `ut-caddy-config` | Caddy configuration |
| `ut-redis-data` | Redis AOF persistence |
| `ut-mongodb-data` | MongoDB database files |
| `ut-mongodb-backup` | Compressed backup archives |
| `ut-uploads-data` | Shared file uploads (API + Workers) |
| `ut-llm-ollama` | Ollama configuration |
| `ut-llm-models` | LLM model files |

## Common Operations

```bash
# View logs
docker compose logs -f api
docker compose logs -f llm

# Restart a service
docker compose restart api

# Scale workers
docker compose up -d --scale workers=4

# Update to latest
git pull
docker compose pull
docker compose up -d

# Enable auto-start on boot
sudo ./setup-autostart.sh

# Install log archival cron job
chmod +x ut-logs.sh
./ut-logs.sh --install
```

## Documentation

Full setup and administration guides can be found at https://docs.understand.tech

- **Installation & Setup** — DGX first-boot, platform deployment, SSL certificates, first-time app config
- **Portainer Guide** — Web-based container management
- **Logging Guide** — Real-time logs, automated archival, log analysis
- **MongoDB & Backups** — Database operations, backup/restore procedures

## Requirements

- NVIDIA DGX Spark (ARM64) with DGX OS
- Docker Engine 24.0+ with Compose V2
- NVIDIA Container Toolkit (pre-installed on DGX)
- GitHub Container Registry access (provided by UnderstandTech)
