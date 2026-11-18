#!/bin/bash
# Boots a real cloud image inside the container, checks the seed reached the guest, and checks a stop powers the guest off cleanly
# It needs root and a host with KVM, which is what the CI runner provides
set -euo pipefail

image="${1:?usage: smoke.sh <image>}"

# The same release werk runs, pinned the same way
readonly cloud_image_url="https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2"
readonly cloud_image_sha256="50bdc5e70f6a24f540932d15411c1c6ae9fcfa40fb990d876d83c5cc823b2ad0"
readonly marker="QEMU_VM_SMOKE_OK"
readonly name="qemu-vm-smoke"

work="$(mktemp -d)"
loop=""

cleanup() {
  podman rm -f -t 0 "$name" >/dev/null 2>&1 || true
  if [ -n "$loop" ]; then
    losetup -d "$loop" || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

dump() {
  echo "--- container log" >&2
  podman logs "$name" >&2 || true
  echo "--- serial console" >&2
  tail -n 100 "$work/state/console.log" >&2 || true
}

# A sparse file behind a loop device stands in for the iSCSI LUN the container gets in production
truncate -s 8G "$work/disk.img"
loop="$(losetup --find --show "$work/disk.img")"

mkdir -p "$work/state" "$work/seed"

# The host downloads the image in production too, because the container has no network of its own
echo "Downloading the cloud image"
curl -fsSL --retry 5 -o "$work/state/cloud-image.qcow2" "$cloud_image_url"
echo "$cloud_image_sha256  $work/state/cloud-image.qcow2" | sha256sum -c --status
cat > "$work/seed/meta-data" <<EOF
instance-id: smoke
local-hostname: smoke
EOF
cat > "$work/seed/user-data" <<EOF
#cloud-config
runcmd:
  - [sh, -c, "echo $marker > /dev/ttyS0"]
EOF

# The default bridge network is enough here, since the test only needs the tc plumbing to come up, not a reachable guest
podman run -d --name "$name" \
  --device /dev/kvm \
  --device /dev/net/tun \
  --device /dev/vhost-net \
  --device "$loop:/dev/vm-disk" \
  --cap-add NET_ADMIN \
  --security-opt label=disable \
  --stop-timeout 120 \
  -v "$work/state:/vm/state" \
  -v "$work/seed:/vm/seed:ro" \
  -e VM_NAME=smoke \
  -e VM_CPUS=2 \
  -e VM_MEMORY=2048 \
  -e VM_MAC=02:00:00:00:00:01 \
  -e VM_STOP_TIMEOUT=90 \
  -e VM_CLOUD_IMAGE=/vm/state/cloud-image.qcow2 \
  -e VM_CLOUD_IMAGE_SHA256="$cloud_image_sha256" \
  "$image" >/dev/null

echo "Waiting for the guest to run the seed's command"
for _ in $(seq 1 120); do
  if grep -q "$marker" "$work/state/console.log" 2>/dev/null; then
    break
  fi
  if [ "$(podman inspect --format '{{.State.Running}}' "$name")" != "true" ]; then
    dump
    echo "FAIL: the container exited before the guest finished booting" >&2
    exit 1
  fi
  sleep 5
done
if ! grep -q "$marker" "$work/state/console.log" 2>/dev/null; then
  dump
  echo "FAIL: the guest never ran the command from the seed" >&2
  exit 1
fi
echo "The guest booted and applied the seed"

if blkid -p "$loop" >/dev/null 2>&1; then
  echo "The disk carries the cloud image"
else
  dump
  echo "FAIL: the disk is still blank" >&2
  exit 1
fi

echo "Stopping the container, which must power the guest off"
podman stop -t 120 "$name" >/dev/null
exit_code="$(podman inspect --format '{{.State.ExitCode}}' "$name")"
if [ "$exit_code" != "0" ] || podman logs "$name" 2>&1 | grep -q "did not power off"; then
  dump
  echo "FAIL: the guest was not powered off cleanly (exit code $exit_code)" >&2
  exit 1
fi
echo "PASS: the guest powered off cleanly"
