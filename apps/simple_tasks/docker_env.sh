# Settings for the container scripts in this folder (docker_*.sh, dpu_service.sh).
# Sourced, not run. Override any of them from the environment, e.g.
#   HOST_IMAGE=dfjrt321/odos-mpi:dev-doca-3.5 ./docker_compile.sh

# Host image with ODOS clang and the aarch64 cross toolchain (README: "Build the host image")
HOST_IMAGE=${HOST_IMAGE:-odos-mpi-dev}

# DPU image that runs the ODOS service
DPU_IMAGE=${DPU_IMAGE:-docker.io/dfjrt321/odos-mpi:dpu-doca-3.5}

# The host's DOCA install, mounted read-only into the host container
DOCA_PATH=${DOCA_PATH:-/opt/mellanox/doca}

# RDMA devices the host container may use, e.g. "uverbs2 uverbs3"; empty means
# all of /dev/infiniband. The ODOS plugin offloads to the first BlueField it
# finds, so on a host with two BlueFields this picks which DPU a task runs on.
ODOS_UVERBS=${ODOS_UVERBS:-}

# Directory on the DPU for task c's liblog_aarch64.so; the service has it on its
# library path
DPU_TASKS_DIR=${DPU_TASKS_DIR:-/tmp/odos-tasks}
