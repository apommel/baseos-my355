# Shared Docker platform helpers for BaseOS build scripts.
# Source from a script that has set HERE to the repository root:
#   . "$HERE/tools/docker-platform.sh"
#
# BASEOS_DOCKER_PLATFORM_HOST  — this machine's CPU, or the environment override
# BASEOS_DOCKER_PLATFORM_AARCH64 — device/userspace arch for the handheld

BASEOS_DOCKER_PLATFORM_AARCH64=linux/arm64

if [ -z "${BASEOS_DOCKER_PLATFORM_HOST:-}" ]; then
  case "$(uname -m)" in
    arm64|aarch64) BASEOS_DOCKER_PLATFORM_HOST=linux/arm64 ;;
    x86_64|amd64)  BASEOS_DOCKER_PLATFORM_HOST=linux/amd64 ;;
    *)
      echo "unsupported host architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

# Docker Desktop and OrbStack register the binfmt handlers an x86 host needs to run
# linux/arm64; a plain Docker Engine does not, and fails with "exec format error".
baseos_require_aarch64() {
  [ "$BASEOS_DOCKER_PLATFORM_HOST" = "$BASEOS_DOCKER_PLATFORM_AARCH64" ] && return 0
  err="$(docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
           alpine:3.20 /bin/true 2>&1)" && return 0
  echo "cannot run $BASEOS_DOCKER_PLATFORM_AARCH64 containers on this $(uname -m) host:" >&2
  printf '%s\n' "$err" | sed 's/^/  /' >&2
  echo >&2
  echo "Register the QEMU binfmt handlers, then re-run:" >&2
  echo "  docker run --privileged --rm tonistiigi/binfmt --install arm64" >&2
  exit 1
}
