# Building this container

```bash
export HOST_DOCA_PATH=/opt/mellanox/doca
docker buildx build --platform linux/arm64 \
  --build-context doca="${HOST_DOCA_PATH}" \
  -f dpu_scripts/Dockerfile -t odos-mpi-dpu .
```