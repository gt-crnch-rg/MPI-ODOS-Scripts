#!/usr/bin/env bash
#
# Installs required build/toolchain packages on Ubuntu, choosing the
# correct package set based on host architecture (x86_64 or aarch64).

#Check for x86 or aarch64 architecture 
ARCH="$(uname -m)"
 
PKGS=(
  flex
  build-essential
  binutils-dev
  autoconf
  automake
  libtool
  binutils
  gcc-12
  g++-12
  libc++-14-dev
  libc++-dev
  libc++1-14
  libc++abi-14-dev
  libc++abi-dev
  libc++abi1-14
  libunwind-14
  libunwind-14-dev
  clang-14
)
 
case "$ARCH" in
  x86_64|aarch64)
    echo "Detected $ARCH host."
    ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

# Require elevated privileges: run as root or via sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "This script must be run as root or with sudo privileges." >&2
  exit 1
fi
 
echo "Updating package lists..."
${SUDO} apt update
 
echo "Installing packages: ${PKGS[*]}"
${SUDO} apt install -y "${PKGS[@]}"
 
echo "Done."
