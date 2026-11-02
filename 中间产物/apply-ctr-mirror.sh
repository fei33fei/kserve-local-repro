#!/bin/sh
# 在 kind 节点的 containerd 配置里启用 registry hosts 目录
set -e
CFG=/etc/containerd/config.toml

if ! grep -q 'io.containerd.grpc.v1.cri".registry]' "$CFG"; then
  {
    printf '\n'
    printf '[plugins."io.containerd.grpc.v1.cri".registry]\n'
    printf '  config_path = "/etc/containerd/certs.d"\n'
  } >> "$CFG"
  echo "appended registry config_path"
else
  echo "registry section already present"
fi

mkdir -p /etc/containerd/certs.d/docker.io
echo "--- hosts.toml ---"
cat /etc/containerd/certs.d/docker.io/hosts.toml
echo "--- config.toml tail ---"
tail -6 "$CFG"
