# Spegel for Nomad
[Spegel](https://github.com/spegel-org/spegel) is a stateless, local OCI
registry mirror.

Originally designed to run on Kubernetes, Spegel can now be run as a `system`
job on Nomad with a couple of configuration changes to `docker` and `containerd`.

This repository contains all the necessary Nomad job files and configuration
changes required to deploy Spegel on Nomad.

Please note that nomad-spegel currently only works for dockerhub.io images as
docker/moby does not support mirroring other registries. As a workaround you
can still pull non dockerhub images if you use another client that interfaces
with containerd such as `nerdctl` and use the `moby` `namespace`.

## Requirements

* Docker CE version on 24+, although I would recommend using the latest (26+ at time of writing)
* Nomad cluster
* Consul cluster (optional)

## Config changes
containerd configuration `/etc/containerd/config.toml` file needs updating to

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
   config_path = "/etc/containerd/certs.d"
[plugins."io.containerd.grpc.v1.cri".containerd]
   discard_unpacked_layers = false

```

dockerd configuration `/etc/docker/daemon.json`

```
{
  "registry-mirrors": [
    "http://localhost:30021",
    "http://spegel.service.consul:30021"
  ],
  "insecure-registries":[
    "localhost:30021",
    "spegel.service.consul:30021"
  ],
  "features": {
    "containerd-snapshotter": true
  }
}
```

Once both of these configurations have been updated you should restart docker
and containerd for them to take effect.

## Deploying Spegel
### Spegel without Consul
If you're running Nomad without consul you have two options for deployment:

1. Nomad with [NomadService](https://developer.hashicorp.com/nomad/docs/job-specification/template#simple-load-balancing-with-nomad-services) rendezvous hashing.
2. Nomad with kv lock for leader election

Overall, I find deploying **Spegel with the kv lock method with Nomad or Consul
for leader election the most reliable**. If you want to deploy Spegel in the most
fault tolerant method registering the Spegel service in Consul allows for you
to take advantage of the service
[DNS](https://developer.hashicorp.com/consul/docs/services/discovery/dns-static-lookups#perform-static-dns-queries)
hostname in the event that the local Spegel instance is down.

#### Spegel via NomadService
Deploy Spegel using NomadService and the rendezvous hashing algorithm for
leader election.

```
nomad job run job-files/spegel-ns.hcl
```

#### Spegel with Nomad kv and service
Deploy spegel using Nomad kv and Nomad service registration
```
nomad job run -var-file=./vars/nomad-kv-ns.hcl job-files/spegel-kv.hcl
```

#### Spegel with Nomad kv and Consul service
Deploy spegel using Nomad kv and Consul service registration
```
nomad job run -var-file=./vars/nomad-kv-cs.hcl job-files/spegel-kv.hcl
```

#### Spegel with Consul kv and Consul service
Deploy spegel using Consul kv and Consul service registration
```
nomad job run -var-file=./vars/consul-kv.hcl job-files/spegel-kv.hcl
```

## Configuring spegel
Please see [Spegel](https://github.com/spegel-org/spegel) main repo for
configuration. The current configuration follows the helm chart from the Spegel
repo. Below are the options for configuring the different aspects of the
templates.

### Configuration
See the [vars/](vars/) folder for example implementations. To define the spegel
config map you need to define the full map.

Config map for configuring the Spegel service
```
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
```

Service configuration for exposing the registry service port and service
healthchecks
```
--- Spegel service configuration ---
provider: >-
  Name of the service provider, either consul or nomad. For rendezvous hashing,
  only nomad is supported.
registry:
  port: Port on which the registry service will be exposed
```

Bootstrap configuration (only used in
[job-files/spegel-kv.hcl](job-files/spegel-kv.hcl)) for leader election using
distributed locking. Either consul or nomad can be used as a kv backend.

Current implementation of the bootstrap tool uses the hosts consul/nomad binary
inside a debian-slim container. If ACLs are in place support for passing the
NOMAD/CONSUL API token to the job would need to be implemented.

```
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
```
