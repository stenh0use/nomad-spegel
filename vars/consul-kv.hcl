bootstrap = {
  key_prefix = "nomad/jobs"
  provider = {
    name = "consul"
    bin  = "/bin/consul"
  }
  image = {
    name = "docker.io/debian"
    tag  = "bookworm-slim"
  }
}
