#!/usr/bin/env bash
#
# Installs required build/toolchain packages on Ubuntu, choosing the
# correct package set based on host architecture (x86_64 or aarch64).
# This script also installs Docker for the Docker build pathway

set -euo pipefail

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
  docker.io
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
 
echo "Updating package lists..."
sudo apt update
 
echo "Installing packages: ${PKGS[*]}"
sudo apt install -y "${PKGS[@]}"
 
echo "Done."
