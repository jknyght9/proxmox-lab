# =============================================================================
# Forgejo Actions runner — CI executor for the Forgejo forge
#
# Polls the Forgejo instance (git.<postfix>) OUTBOUND and runs workflow jobs
# in throwaway Docker containers. There is NO inbound web UI, so — unlike the
# other Layer-2 services — this job has NO Traefik route and NO DNS record.
#
# One task group, two tasks:
#   - `dind`   (prestart sidecar): a Docker-in-Docker daemon that actually
#              spawns the job containers. Running our own daemon (rather than
#              bind-mounting the host's /var/run/docker.sock) keeps CI
#              workloads isolated from the host's Nomad-managed containers.
#   - `runner` : the forgejo-runner itself. Registers once (idempotent — the
#              `.runner` file is persisted on the NFS volume) then runs the
#              daemon, talking to dind over loopback and to Forgejo over HTTPS.
#
# Pinned to nomad03 (same node as forgejo/kaneo/netbox). Host networking is
# used, so every static port must stay clear of the other services co-located
# on nomad03 (netbox: http 8080, pg 5433, redis 6380, unit-status 8082;
# forgejo: http 3000, ssh 2222, pg 5435; kaneo: http 5173, pg 5436). The dind
# daemon listens on loopback :2375 (verified free on nomad03, 2026-10-03).
#
# Image pins (verified 2026-10-03):
#   - code.forgejo.org/forgejo/runner:13.1.0  (current stable runner; v13.1.0
#     released 2026-08-31. Both code.forgejo.org and data.forgejo.org publish
#     it — we use code.forgejo.org per the integration brief.)
#   - docker:28-dind  (current Docker stable; with DOCKER_TLS_CERTDIR="" the
#     stock dind entrypoint starts dockerd on tcp://0.0.0.0:2375 + the unix
#     socket, so loopback :2375 reaches it from the host netns.)
#
# Registration (instance-level): a reusable registration token is minted by
# null_resource.forgejo_runner_token, which runs Forgejo's own CLI
# (`forgejo actions generate-runner-token`) via `nomad alloc exec` — no admin
# API token needed — and writes it to Vault at secret/forgejo-runner.
# Instance-level means ANY repo/org on this instance can schedule jobs on
# this runner — the sensible default for a single-tenant lab. NOTE: on first
# boot the runner may restart a couple of times until the dind sidecar's
# daemon is accepting connections; it self-heals and then stays up.
# =============================================================================
job "forgejo-runner" {
  datacenters = ["dc1"]
  type        = "service"

  group "runner" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad03"
    }

    # Allow extra time for the dind + runner image pulls on first run.
    update {
      min_healthy_time  = "20s"
      healthy_deadline  = "10m"
      progress_deadline = "15m"
    }

    # Node-local scratch for the dind data-root + runner cache/workdir. These
    # MUST NOT live on NFS — overlayfs (dind's storage driver) does not work on
    # NFS, and CI cache/workdir churn would hammer the NAS. ephemeral_disk is
    # on the client's local disk; losing it on reschedule only drops the image
    # layer cache, which dind repopulates.
    ephemeral_disk {
      size    = 10000
      migrate = false
      sticky  = true
    }

    vault {
      role        = "forgejo-runner"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "dind" { static = 2375 }
    }

    # Small, durable state only: the runner registration (`.runner`) + its
    # rendered config. Safe on NFS (tiny, rarely written). Snapshotted on the
    # cluster_state NAS like every other service dataset.
    volume "data" {
      type            = "csi"
      source          = "forgejo-runner-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    # --- Docker-in-Docker daemon (job-container engine) ---
    task "dind" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image        = "docker:28-dind"
        network_mode = "host"
        privileged   = true
        # Plain TCP on loopback only (host netns) — no TLS to keep the
        # runner↔daemon hop simple. Not exposed off-box: 2375 binds to the
        # host but the firewall/trust model keeps it on the cluster subnet,
        # and nothing routes loopback. Store layers on node-local scratch.
        args = ["--data-root=/alloc/data/docker"]
      }

      env {
        # Empty cert dir disables TLS; stock dind entrypoint then serves
        # dockerd on tcp://0.0.0.0:2375 + unix:///var/run/docker.sock.
        DOCKER_TLS_CERTDIR = ""
      }

      resources {
        cpu    = 500
        memory = 1024
      }
    }

    # --- Forgejo Actions runner ---
    task "runner" {
      driver = "docker"
      # Run as root: the runner image is "user-mode" (non-root) by default and
      # cannot write its .runner config onto the NFS/CSI volume (root-owned, no
      # squash — same as the postgres tasks, which also run as root on NFS).
      user = "root"

      config {
        image        = "code.forgejo.org/forgejo/runner:13.1.0"
        network_mode = "host"
        # Override the image entrypoint with our register-once-then-daemon
        # wrapper (rendered to /local/run.sh below).
        entrypoint = ["/bin/sh", "/local/run.sh"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
        read_only   = false
      }

      # Root CA from Vault so the runner (Go, honours SSL_CERT_FILE) trusts the
      # internal CA when it registers/polls against https://git.<postfix>. The
      # runner only ever speaks HTTPS to the internal instance (image pulls are
      # dind's job, in its own stock trust store), so pointing SSL_CERT_FILE at
      # just our CA is sufficient — same approach as the forgejo app task.
      template {
        data        = <<EOH
{{ with secret "pki/cert/ca" }}{{ .Data.certificate }}{{ end }}
EOH
        destination = "local/certs/root_ca.crt"
        perms       = "0644"
        change_mode = "noop"
      }

      # Runtime env — registration token from Vault + static wiring.
      template {
        data = <<EOH
FORGEJO_INSTANCE_URL=https://git.${dns_postfix}
{{ with secret "secret/data/forgejo-runner" }}
FORGEJO_RUNNER_REGISTRATION_TOKEN={{ .Data.data.registration_token }}
{{ end }}
# Runner labels: a label maps a workflow `runs-on:` value to the image the job
# runs in (docker://<image>). Sane lab defaults; extend as workflows need.
RUNNER_LABELS=docker:docker://node:20-bookworm,ubuntu-22.04:docker://node:20-bookworm,ubuntu-latest:docker://node:20-bookworm
# The runner is Go — trust the internal CA for the HTTPS hop to Forgejo.
SSL_CERT_FILE=/local/certs/root_ca.crt
# Job containers that themselves call docker reach the dind daemon here.
DOCKER_HOST=tcp://127.0.0.1:2375
EOH
        destination = "secrets/runner.env"
        env         = true
      }

      # Runner config. docker_host points at the dind sidecar; cache + workdir
      # live on node-local scratch (/alloc/data), never NFS. The `.runner`
      # registration file is kept on the NFS volume (/data) so a restart or
      # reschedule does not re-register a duplicate runner.
      template {
        data = <<EOH
log:
  level: info
runner:
  file: /data/.runner
  capacity: 2
  timeout: 3h
  fetch_timeout: 5s
  fetch_interval: 2s
  labels: []
cache:
  enabled: true
  dir: /alloc/data/runner-cache
container:
  network: ""
  privileged: false
  docker_host: tcp://127.0.0.1:2375
  valid_volumes: []
  force_pull: false
host:
  workdir_parent: /alloc/data/workdir
EOH
        destination = "local/config.yaml"
        perms       = "0644"
        change_mode = "restart"
      }

      # Register once (idempotent via the persisted /data/.runner), then run
      # the daemon. Shell variable refs are triple-dollar-escaped in this .tpl
      # so they survive BOTH layers (templatefile first, then Nomad jobspec
      # parse) and reach the file as a literal shell variable reference the
      # shell expands at runtime. (Nomad attr-dot interpolations elsewhere are
      # single-escaped on purpose, because we WANT Nomad to resolve those.)
      template {
        data = <<EOH
#!/bin/sh
set -e
cd /data

if [ ! -f /data/.runner ]; then
  if [ -z "$$${FORGEJO_RUNNER_REGISTRATION_TOKEN}" ]; then
    echo "[forgejo-runner] No registration token in secret/forgejo-runner."
    echo "[forgejo-runner] Re-apply so null_resource.forgejo_runner_token can"
    echo "[forgejo-runner] generate one (forgejo actions generate-runner-token),"
    echo "[forgejo-runner] then restart this job. Exiting."
    exit 1
  fi
  echo "[forgejo-runner] Registering against $$${FORGEJO_INSTANCE_URL} ..."
  forgejo-runner register --no-interactive \
    --instance "$$${FORGEJO_INSTANCE_URL}" \
    --token "$$${FORGEJO_RUNNER_REGISTRATION_TOKEN}" \
    --name "nomad-$$${NOMAD_SHORT_ALLOC_ID:-forgejo-runner}" \
    --labels "$$${RUNNER_LABELS}"
fi

echo "[forgejo-runner] Starting daemon ..."
exec forgejo-runner daemon --config /local/config.yaml
EOH
        destination = "local/run.sh"
        perms       = "0755"
        change_mode = "restart"
      }

      resources {
        cpu    = 500
        memory = 512
      }

      # No service{} stanza: the runner publishes nothing and is not fronted by
      # Traefik. Nomad still reports task health from the running daemon.
    }
  }
}
