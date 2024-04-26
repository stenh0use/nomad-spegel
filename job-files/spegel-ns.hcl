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
  provider: Name of the service provider. For rendevouz hashing, only nomad is supported
  registry:
    port: Port on which the registry service will be exposed
  EOF

  default = {
    provider = "nomad"
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
          grace           = "60s"
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
          grace           = "60s"
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
        data        = <<-EOH
        {{- range nomadService 1 "${var.spegel.name}" "${var.spegel.name}" -}}
        HTTP_BOOTSTRAP_PEER="http://{{ .Address }}:{{ .Port }}/id"
        {{- end -}}
        EOH
        destination = "local/bootstrap.env"
        env         = true
        change_mode = "restart"
      }
    }
  }
}
