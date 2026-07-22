// docker buildx bake definitions for the two custom-built services.
// No bake target exists for postgres/redis/caddy/minio/n8n — those are
// official multi-arch images pulled as-is; building a wrapper around them
// would be exactly the "meaningless custom wrapper" this project avoids.
//
// Usage (see scripts/build-*.sh for the wrapped versions):
//   docker buildx bake amd64            # local AMD64 images, loaded into `docker images`
//   docker buildx bake arm64            # QEMU-emulated ARM64 images, loaded into `docker images`
//   docker buildx bake default --push   # both platforms — requires REGISTRY set to a real registry

variable "REGISTRY" {
  default = "ai-youtube-automation"
}

variable "TAG" {
  default = "local"
}

group "default" {
  targets = ["renderer", "approval-api"]
}

group "amd64" {
  targets = ["renderer-amd64", "approval-api-amd64"]
}

group "arm64" {
  targets = ["renderer-arm64", "approval-api-arm64"]
}

target "base" {
  platforms = ["linux/amd64", "linux/arm64"]
}

target "renderer" {
  inherits   = ["base"]
  context    = "./apps/renderer"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/renderer:${TAG}"]
}

target "approval-api" {
  inherits   = ["base"]
  context    = "./apps/approval-api"
  dockerfile = "Dockerfile"
  tags       = ["${REGISTRY}/approval-api:${TAG}"]
}

// Single-platform variants: multi-platform build results can only be
// --push-ed to a registry, not --load-ed into the local `docker images`
// store. These exist so local dev/CI can build+load one architecture at a
// time for smoke-testing before a registry is in the picture.
target "renderer-amd64" {
  inherits  = ["renderer"]
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/renderer:${TAG}-amd64"]
}

target "renderer-arm64" {
  inherits  = ["renderer"]
  platforms = ["linux/arm64"]
  tags      = ["${REGISTRY}/renderer:${TAG}-arm64"]
}

target "approval-api-amd64" {
  inherits  = ["approval-api"]
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/approval-api:${TAG}-amd64"]
}

target "approval-api-arm64" {
  inherits  = ["approval-api"]
  platforms = ["linux/arm64"]
  tags      = ["${REGISTRY}/approval-api:${TAG}-arm64"]
}
