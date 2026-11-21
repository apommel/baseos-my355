# Sourced by bash through BASH_ENV. Once, so nested shells keep one PATH.
if [ -z "${FLIPBASE_SDK_ENV:-}" ]; then
  . "$FLIPBASE_SDK/environment-setup" >/dev/null
  export FLIPBASE_SDK_ENV=1
fi
