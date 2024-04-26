bootstrap = {
  key_prefix = "nomad/jobs"
  provider = {
    name = "nomad"
    bin  = "/bin/nomad"
  }
  image = {
    name = "docker.io/debian"
    tag  = "bookworm-slim"
  }
}

service = {
  provider = "nomad"
  registry = {
    port = 30021
  }
}
