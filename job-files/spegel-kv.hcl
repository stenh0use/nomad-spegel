variable "spegel" {
  description = <<-EOF
  Configuration related to the Spegel registry task.

  --- Spegel registry configuration ---
  name: Name of the Spegel registry job on Nomad
  image:
    name: Name of the Spegel registry image
    tag: Tag of the Spegel registry image
    sha256: SHA256 of the Spegel registry image (TODO)
  resources:
    cpu: CPU resources to allocate to the Spegel registry
    memory: Memory resources to allocate to the Spegel registry
    memory_max: Maximum memory resources to allocate to the Spegel registry
  registries: List of registries for which mirror configuration will be created
  mirrorResolveRetries: Number of retries for resolving a mirror
  mirrorResolveTimeout: Maximum duration spent finding a mirror
  containerdSock: Path to the Containerd socket
  containerdNamespace: Containerd namespace where images are stored
  containerdRegistryConfigPath: Path to the Containerd mirror configuration
  containerdMirrorAdd: If true Spegel will add mirror configuration to the node
  resolveTags: When true Spegel will resolve tags to digests
  resolveLatestTag: When true latest tags will be resolved to digests
  EOF

  default = {
    name = "spegel"
    image = {
      name = "ghcr.io/spegel-org/spegel"
      tag  = "v0.0.21"
    }
    resources = {
      cpu        = 1000
      memory     = 128
      memory_max = 256
    }
    registries = [
      "https://docker.io",
      "https://ghcr.io",
      "https://quay.io",
      "https://mcr.microsoft.com",
      "https://public.ecr.aws",
      "https://gcr.io",
    ]
    mirrorResolveRetries         = 3
    mirrorResolveTimeout         = "5s"
    containerdSock               = "/run/containerd/containerd.sock"
    containerdNamespace          = "moby"
    containerdRegistryConfigPath = "/etc/containerd/certs.d"
    containerdMirrorAdd          = true
    resolveTags                  = true
    resolveLatestTag             = true
  }

  type = object({
    name = string
    image = object({
      name = string
      tag  = string
    })
    resources = object({
      cpu        = number
      memory     = number
      memory_max = number
    })
    registries                   = list(string)
    mirrorResolveRetries         = number
    mirrorResolveTimeout         = string
    containerdSock               = string
    containerdNamespace          = string
    containerdRegistryConfigPath = string
    containerdMirrorAdd          = bool
    resolveTags                  = bool
    resolveLatestTag             = bool
  })
}

variable "service" {
  description = <<-EOF
  Service configuration for exposing the registry service port

  --- Spegel service configuration ---
  provider: Name of the service provider, either consul or nomad
  registry:
    port: Port on which the registry service will be exposed
  EOF

  default = {
    provider = "consul"
    registry = {
      port = 30021
    }
  }

  type = object({
    provider = string
    registry = object({
      port = number
    })
  })
}

variable "bootstrap" {
  description = <<-EOF
    Leader election configuration, can use either consul or nomad as a kv backend

    --- Spegel bootstrap configuration ---
    key_prefix: Prefix for the leader election and bootstrap keys to be placed under.
    provider: Configuration for the kv provider.
      options:
        name: Name of the kv provider, either consul or nomad.
        bin: Path to the kv provider binary on the nomad client.
    image:
      name: Name of the leader election image
      tag: Tag of the leader election image
      sha256: SHA256 of the leader election image (TODO)
    support bash, and should be compatible with the nomad/consul bin
  EOF

  default = {
    key_prefix = "nomad/jobs"
    provider = {
      name = "consul"
      bin  = "/bin/consul"
    }
    image = {
      name = "docker.io/debian"
      tag  = "bookworm-slim"
    }
    resources = {
      cpu        = 100
      memory     = 128
      memory_max = 256
    }
  }

  type = object({
    key_prefix = string
    provider = object({
      name = string
      bin  = string
    })
    image = object({
      name = string
      tag  = string
    })
  })
}

locals {
  bootstrap = {
    key_prefix = join(
      "/",
      [var.bootstrap.key_prefix, var.spegel.name, "bootstrap"]
    )
  }
}

job "spegel" {
  priority = 100
  type     = "system"

  update {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "15s"
  }

  group "spegel" {
    network {
      port "registryService" {
        static = var.service.registry.port
        to     = var.service.registry.port
      }
      port "registryHost" {}
      port "router" {}
      port "metrics" {}
      port "bootstrap" {}
    }

    service {
      tags     = ["router"]
      name     = var.spegel.name
      port     = "router"
      provider = var.service.provider
      check {
        name     = "router_up"
        type     = "tcp"
        interval = "5s"
        timeout  = "2s"
        check_restart {
          limit           = 5
          grace           = "30s"
          ignore_warnings = false
        }
      }
    }

    service {
      tags     = ["metrics"]
      name     = var.spegel.name
      port     = "metrics"
      provider = var.service.provider
      check {
        name     = "metrics_healthy"
        type     = "http"
        path     = "/metrics"
        interval = "5s"
        timeout  = "2s"
        check_restart {
          limit           = 5
          grace           = "30s"
          ignore_warnings = false
        }
      }
    }

    service {
      tags     = ["bootstrap"]
      name     = var.spegel.name
      port     = "bootstrap"
      provider = var.service.provider
      check {
        name     = "bootstrap_healthy"
        type     = "http"
        path     = "/id"
        interval = "5s"
        timeout  = "2s"
        check_restart {
          limit           = 5
          grace           = "30s"
          ignore_warnings = false
        }
      }
    }

    service {
      tags     = ["registry"]
      name     = var.spegel.name
      port     = "registryService"
      provider = var.service.provider
      check {
        name     = "registry_healthy"
        type     = "http"
        path     = "/healthz"
        interval = "5s"
        timeout  = "2s"
        check_restart {
          limit           = 5
          grace           = "30s"
          ignore_warnings = false
        }
      }
    }

    task "configuration" {
      driver = "docker"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        image = join(":", [var.spegel.image.name, var.spegel.image.tag])
        volumes = [
          join(":", [var.spegel.containerdRegistryConfigPath, var.spegel.containerdRegistryConfigPath])
        ]
        args = concat([
          "configuration",
          "--containerd-registry-config-path=${var.spegel.containerdRegistryConfigPath}",
          "--resolve-tags=${var.spegel.resolveTags}",
          "--mirror-registries"
          ],
          var.service.provider == "consul" ? [
            "http://${NOMAD_ADDR_registryService}",
            "http://${var.spegel.name}-registry.service.consul:${NOMAD_PORT_registryService}"
            ] : [
            "http://${NOMAD_ADDR_registryService}"
          ],
          [
            "--registries",
          ],
          var.spegel.registries,
        )
      }
    }

    task "registry" {
      driver = "docker"

      restart {
        interval = "5m"
        attempts = 5
        delay    = "15s"
        mode     = "delay"
      }

      resources {
        cpu        = try(var.spegel.resorces.cpu, 1000)
        memory     = try(var.spegel.resorces.memory, 128)
        memory_max = try(var.spegel.resorces.memory_max, 256)
      }

      config {
        network_mode = "host"
        image        = join(":", [var.spegel.image.name, var.spegel.image.tag])
        ports        = ["registryService", "registryHost", "router", "metrics", "bootstrap"]
        volumes = [
          join(":", [var.spegel.containerdRegistryConfigPath, var.spegel.containerdRegistryConfigPath]),
          join(":", [var.spegel.containerdSock, var.spegel.containerdSock]),
        ]
        args = concat([
          "registry",
          "--mirror-resolve-retries=${var.spegel.mirrorResolveRetries}",
          "--mirror-resolve-timeout=${var.spegel.mirrorResolveTimeout}",
          "--registry-addr=:${NOMAD_PORT_registryService}",
          "--router-addr=:${NOMAD_PORT_router}",
          "--metrics-addr=:${NOMAD_PORT_metrics}",
          "--containerd-sock=${var.spegel.containerdSock}",
          "--containerd-namespace=${var.spegel.containerdNamespace}",
          "--containerd-registry-config-path=${var.spegel.containerdRegistryConfigPath}",
          "--bootstrap-kind=http",
          "--http-bootstrap-addr=:${NOMAD_PORT_bootstrap}",
          "--resolve-latest-tag=${var.spegel.resolveLatestTag}",
          "--local-addr=${NOMAD_ADDR_registryHost}",
          "--registries",
          ],
          var.spegel.registries,
        )
      }
      template {
        data = var.bootstrap.provider.name == "consul" ? (
          <<-EOH
          {{- with $k := key "${local.bootstrap.key_prefix}/bootstrap" | parseJSON -}}
          HTTP_BOOTSTRAP_PEER="{{ $k.BOOTSTRAP_DATA }}"
          {{- end -}}
          EOH
          ) : (
          <<-EOH
          {{- with nomadVar "${local.bootstrap.key_prefix}/bootstrap" -}}
          HTTP_BOOTSTRAP_PEER="{{ .BOOTSTRAP_DATA }}"
          {{- end -}}
          EOH
        )
        destination = "local/bootstrap.env"
        env         = true
        change_mode = "restart"
      }
    }

    task "bootstrap" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      resources {
        cpu        = try(var.bootstrap.resorces.cpu, 100)
        memory     = try(var.bootstrap.resorces.memory, 32)
        memory_max = try(var.bootstrap.resorces.memory_max, 128)
      }

      env {
        KV_PROVIDER       = var.bootstrap.provider.name
        KV_BIN            = var.bootstrap.provider.bin
        KV_PREFIX         = local.bootstrap.key_prefix
        KV_BOOTSTRAP_DATA = "http://${NOMAD_ADDR_bootstrap}/id"
        KV_HTTP_ADDR = format(
          "http://${NOMAD_HOST_IP_bootstrap}:%s",
          var.bootstrap.provider.name == "consul" ? "8500" : "4646"
        )
      }

      config {
        image = join(":", [var.bootstrap.image.name, var.bootstrap.image.tag])
        args = [
          "${NOMAD_TASK_DIR}/bin/bootstrap",
        ]

        # mount the nomad or consul bin inside the container
        volumes = [
          join(":", [
            var.bootstrap.provider.bin,
            "/usr/local/bin/${basename(var.bootstrap.provider.name)}"
          ])
        ]
      }

      template {
        destination = "local/bin/bootstrap"
        perms       = "755"
        data        = <<-EOF
        #!/usr/bin/env bash
        # basic leader election script using consul/nomad CLI

        # set bash as the shell for consul lock
        export SHELL=$(which bash)
        export PATH=$PATH:$(dirname $KV_BIN)

        required_vars=(
          KV_PROVIDER
          KV_PREFIX
          KV_BIN
          KV_BOOTSTRAP_DATA
          KV_HTTP_ADDR
        )

        log_message() {
          echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
        }

        shutdown_message() {
          log_message "Recieved SIGTERM, shutting down leader election process"
          exit 0
        }

        check_env_var() {
          local var_name="$1";
          local var_value="$${!var_name}";

          if [ -z "$var_value" ]; then
            log_message "'$var_name' env var is not defined";
            return 1;
          else
            return 0;
          fi;
        }

        update_consul_key() {
          consul kv put $1 "{\"BOOTSTRAP_DATA\":\"$2\"}" 2> /dev/null
        }

        update_nomad_key() {
          nomad var put $1 "BOOTSTRAP_DATA=$2" 2> /dev/null
        }

        update_bootstrap_key() {
          local provider=$1
          local bootstrap_key=$2
          local bootstrap_data=$3

          log_message "Acquired lock on leader key"
          update_$${provider}_key "$bootstrap_key" "$bootstrap_data" || {
            log_message "Failed to update bootstrap key"
            return 1
          }
          log_message "Updated bootstrap key with - '$bootstrap_data'"
          log_message "Node is now the leader"

          # sleep forever to hold the lock
          sleep infinity
        }

        session_lock() {
          local provider=$1
          local leader_key="$2"
          local bootstrap_key="$3"
          local bootstrap_data="$4"
          local lock_command=($${@:5})

          log_message "Attempting to acquire lock on '$leader_key'"
          # no timeout means we try until the lock becomes available
          $${lock_command[@]} -shell $leader_key "\
            update_bootstrap_key \
              $provider \
              $bootstrap_key \
              $bootstrap_data \
          " || {
            log_message "Failed to acquire lock"
            return 1
          }
        }

        # ----- setup and initial checks ----

        # make the functions available to lock subshells
        export -f \
          update_bootstrap_key \
          log_message \
          update_consul_key \
          update_nomad_key

        if [ "$KV_PROVIDER" == "consul" ]; then
          export CONSUL_HTTP_ADDR="$KV_HTTP_ADDR"
          lock_command=(consul lock)
          log_message "Using consul for leader election"

        elif [ "$KV_PROVIDER" == "nomad" ]; then
          export NOMAD_ADDR="$KV_HTTP_ADDR"
          lock_command=(nomad var lock)
          log_message "Using nomad for leader election"

        else
          log_message "Unsupported kv provider"
          exit 1
        fi

        for var in "$${required_vars[@]}"; do
          check_env_var "$var" || undefined_vars=1
        done

        if [ -n "$undefined_vars" ]; then
          log_message "Undefined env vars detected"
          exit 1
        fi

        trap shutdown_message SIGTERM

        # set kv paths
        leader_key="$KV_PREFIX/leader"
        bootstrap_key="$KV_PREFIX/bootstrap"

        # ----- script starts here ----

        log_message "Starting leader election process"
        while true; do
          session_lock \
            "$KV_PROVIDER" \
            "$leader_key" \
            "$bootstrap_key" \
            "$KV_BOOTSTRAP_DATA" \
            $${lock_command[@]}
        done
        EOF
      }
    }
  }
}
