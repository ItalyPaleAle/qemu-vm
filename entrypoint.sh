#!/bin/bash
# Runs one KVM virtual machine in the foreground of this container, and powers it off cleanly when the container stops
# Everything VM-specific arrives through the environment and the mounts documented in README.md
set -euo pipefail

log() {
  printf '[qemu-vm] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Configuration
VM_NAME="${VM_NAME:-}"
VM_CPUS="${VM_CPUS:-}"
VM_MEMORY="${VM_MEMORY:-}"
VM_MAC="${VM_MAC:-}"
VM_DISK="${VM_DISK:-/dev/vm-disk}"
VM_NET_IF="${VM_NET_IF:-eth0}"
VM_STOP_TIMEOUT="${VM_STOP_TIMEOUT:-120}"
VM_INSTALL_ISO="${VM_INSTALL_ISO:-}"
VM_INSTALL_POLL="${VM_INSTALL_POLL:-10}"
VM_CLOUD_IMAGE="${VM_CLOUD_IMAGE:-}"
VM_CLOUD_IMAGE_SHA256="${VM_CLOUD_IMAGE_SHA256:-}"
VM_SHARES="${VM_SHARES:-}"
VM_EXTRA_ARGS="${VM_EXTRA_ARGS:-}"

readonly STATE_DIR=/vm/state
readonly SEED_DIR=/vm/seed
readonly RUN_DIR=/run/vm
readonly QEMU=/usr/libexec/qemu-kvm
readonly VIRTIOFSD=/usr/libexec/virtiofsd
readonly OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
readonly OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd
# The console log is kept across restarts for debugging, and rotated once it gets this big
readonly CONSOLE_LOG_LIMIT=$((20 * 1024 * 1024))

# Process IDs of the helpers and of QEMU, which the signal handlers need
child_pid=""
qemu_pid=""
share_pids=()
share_args=()
# Set while the disk is being written, so being stopped half-way leaves it blank rather than half-provisioned
provisioning=0

validate() {
  [ -n "$VM_NAME" ] || fail "VM_NAME must be set"
  [[ "$VM_CPUS" =~ ^[1-9][0-9]*$ ]] || fail "VM_CPUS must be a positive integer"
  [[ "$VM_MEMORY" =~ ^[1-9][0-9]*$ ]] || fail "VM_MEMORY must be a positive integer, in MiB"
  [[ "$VM_STOP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "VM_STOP_TIMEOUT must be a positive integer, in seconds"
  [[ "$VM_INSTALL_POLL" =~ ^[1-9][0-9]*$ ]] || fail "VM_INSTALL_POLL must be a positive integer, in seconds"
  VM_MAC="${VM_MAC,,}"
  [[ "$VM_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || fail "VM_MAC must be a MAC address such as 02:00:00:00:00:01"
  if [ -n "$VM_CLOUD_IMAGE" ] || [ -n "$VM_CLOUD_IMAGE_SHA256" ]; then
    if [ -z "$VM_CLOUD_IMAGE" ] || [ -z "$VM_CLOUD_IMAGE_SHA256" ]; then
      fail "VM_CLOUD_IMAGE and VM_CLOUD_IMAGE_SHA256 must be set together"
    fi
    VM_CLOUD_IMAGE_SHA256="${VM_CLOUD_IMAGE_SHA256,,}"
    [[ "$VM_CLOUD_IMAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "VM_CLOUD_IMAGE_SHA256 must be a SHA-256 hex digest"
  fi

  [ -c /dev/kvm ] || fail "/dev/kvm is missing, so the container needs it passed as a device"
  [ -c /dev/net/tun ] || fail "/dev/net/tun is missing, so the container needs it passed as a device"
  [ -c /dev/vhost-net ] || fail "/dev/vhost-net is missing, so the container needs it passed as a device"
  [ -b "$VM_DISK" ] || fail "$VM_DISK is not a block device"
  [ -d "$STATE_DIR" ] || fail "$STATE_DIR must be mounted, because it holds the UEFI variables"
}

# qemu_path doubles every comma, because QEMU's option syntax would otherwise read one as the start of the next option
qemu_path() {
  printf '%s' "${1//,/,,}"
}

# pause sleeps in the background, so a stop signal is handled straight away instead of after the sleep
pause() {
  sleep "$1" &
  child_pid=$!
  wait "$child_pid" || true
  child_pid=""
}

# stop_before_boot handles a stop signal that arrives before QEMU is running
stop_before_boot() {
  if [ -n "$child_pid" ]; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  if [ "$provisioning" = 1 ]; then
    log "Stopped while writing the disk, so it is wiped and will be provisioned again on the next start"
    wipefs -a "$VM_DISK" >/dev/null 2>&1 || true
  fi
  stop_shares
  exit 0
}

# setup_network hands the container's macvlan interface to the guest, following the "tcfilter" model Kata Containers uses
# The interface takes the guest's MAC, so the macvlan delivers the guest's frames to it, and tc moves every frame across to the tap and back
# Nothing in the container's own network stack ever sees a packet, and no device node has to be created at runtime
setup_network() {
  ip link show dev "$VM_NET_IF" >/dev/null 2>&1 || fail "the network interface $VM_NET_IF does not exist"

  local mtu
  mtu="$(cat "/sys/class/net/$VM_NET_IF/mtu")"

  ip link set dev "$VM_NET_IF" down
  ip link set dev "$VM_NET_IF" address "$VM_MAC"
  # Without an address of its own the container never answers ARP, and no IPv6 link-local address is generated either
  # Turning address generation off fails where IPv6 is disabled outright, which is just as good
  ip link set dev "$VM_NET_IF" addrgenmode none 2>/dev/null || true
  ip address flush dev "$VM_NET_IF"

  # A container restarted in place keeps its network namespace, so whatever an earlier run left behind is cleared first
  tc qdisc del dev "$VM_NET_IF" ingress 2>/dev/null || true
  ip link del dev tap0 2>/dev/null || true
  ip tuntap add dev tap0 mode tap
  ip link set dev tap0 addrgenmode none 2>/dev/null || true
  ip link set dev tap0 mtu "$mtu"

  ip link set dev "$VM_NET_IF" up
  ip link set dev tap0 up

  tc qdisc add dev "$VM_NET_IF" ingress
  tc filter add dev "$VM_NET_IF" parent ffff: protocol all u32 match u8 0 0 action mirred egress redirect dev tap0
  tc qdisc add dev tap0 ingress
  tc filter add dev tap0 parent ffff: protocol all u32 match u8 0 0 action mirred egress redirect dev "$VM_NET_IF"

  log "Network: $VM_NET_IF and tap0 are bridged by tc, with MAC $VM_MAC and MTU $mtu"
}

# setup_firmware keeps the UEFI variables on the state mount, so boot entries the guest writes survive a restart
setup_firmware() {
  local vars="$STATE_DIR/efivars.fd"
  if [ -f "$vars" ] && [ "$(stat -c %s "$vars")" != "$(stat -c %s "$OVMF_VARS")" ]; then
    # A firmware update can change the size of the variable store, which QEMU refuses to boot with
    log "The saved UEFI variables do not match this firmware, so they are reset and the guest's boot loader recreates its entry"
    rm -f "$vars"
  fi
  if [ ! -f "$vars" ]; then
    cp "$OVMF_VARS" "$vars"
  fi
}

# disk_is_blank reports whether the disk has neither a partition table nor a filesystem
# Anything blkid cannot decide is treated as data, because overwriting a disk by mistake cannot be undone
disk_is_blank() {
  local status=0
  blkid -p "$VM_DISK" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) return 1 ;;
    2) return 0 ;;
    *) fail "blkid could not probe $VM_DISK (exit code $status), so the disk is left alone" ;;
  esac
}

# provision_cloud_image writes a verified cloud image onto the blank disk
# The host puts the image in place, because the container's only interface belongs to the guest and it has no network of its own
provision_cloud_image() {
  local image="$VM_CLOUD_IMAGE"
  wait_for_file "$image" "the cloud image"

  # The digest is checked here too, since a file the host has not finished writing would otherwise end up on the disk
  echo "$VM_CLOUD_IMAGE_SHA256  $image" | sha256sum -c --status || fail "$image does not match VM_CLOUD_IMAGE_SHA256"

  local format
  format="$(qemu-img info "$image" | sed -n 's/^file format: //p')"
  case "$format" in
    qcow2 | raw) ;;
    *) fail "the cloud image is in format \"$format\", and only qcow2 and raw are supported" ;;
  esac

  log "Writing the $format cloud image onto $VM_DISK"
  provisioning=1
  qemu-img convert -f "$format" -O raw -n -t none "$image" "$VM_DISK" &
  child_pid=$!
  if ! wait "$child_pid"; then
    child_pid=""
    wipefs -a "$VM_DISK" >/dev/null 2>&1 || true
    fail "the cloud image could not be written, so the disk was wiped and will be provisioned again on the next start"
  fi
  child_pid=""
  provisioning=0

  # The image is left where the host put it, so a rebuild needs no download
  log "The cloud image was written, and the guest grows its root filesystem to fill the disk on first boot"
}

# wait_for_file keeps the container running until a provisioning source appears, so the service stays healthy meanwhile
wait_for_file() {
  local path="$1"
  local what="$2"
  local announced=0
  while [ ! -f "$path" ]; do
    if [ "$announced" = 0 ]; then
      log "The disk is blank, so the virtual machine starts once $what exists at $path"
      announced=1
    fi
    pause "$VM_INSTALL_POLL"
  done
}

# rotate_console_log keeps the serial console log from growing without bound
rotate_console_log() {
  local console_log="$STATE_DIR/console.log"
  if [ -f "$console_log" ] && [ "$(stat -c %s "$console_log")" -gt "$CONSOLE_LOG_LIMIT" ]; then
    mv -f "$console_log" "$console_log.1"
  fi
}

# start_shares starts one virtiofsd per share, and collects the QEMU arguments attaching them in share_args
start_shares() {
  local share tag path socket waited
  local -a shares
  share_args=()
  IFS=',' read -ra shares <<< "$VM_SHARES"
  for share in "${shares[@]}"; do
    tag="${share%%:*}"
    path="${share#*:}"
    [[ "$tag" =~ ^[A-Za-z0-9_-]+$ ]] || fail "the share \"$share\" needs a tag made of letters, digits, dashes and underscores"
    [ "$tag" != "$share" ] || fail "the share \"$share\" must be written tag:/path"
    [ -d "$path" ] || fail "the shared directory $path does not exist in the container"

    socket="$RUN_DIR/virtiofs-$tag.sock"
    rm -f "$socket"
    # The container is the sandbox already, and virtiofsd's own one needs privileges a container does not have
    "$VIRTIOFSD" --socket-path="$socket" --shared-dir="$path" --sandbox=none --cache=auto >&2 &
    share_pids+=("$!")

    waited=0
    until [ -S "$socket" ]; do
      [ "$waited" -lt 100 ] || fail "virtiofsd did not start for the share $tag"
      sleep 0.1
      waited=$((waited + 1))
    done
    log "Share: $path is exported to the guest with the tag $tag"
    share_args+=(-chardev "socket,id=fs-$tag,path=$(qemu_path "$socket")" -device "vhost-user-fs-pci,chardev=fs-$tag,tag=$tag")
  done
}

stop_shares() {
  local pid
  for pid in "${share_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}

# qmp sends one command over the QMP socket, which needs the capabilities handshake first on every connection
qmp() {
  printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" \
    | socat -t 2 - "UNIX-CONNECT:$RUN_DIR/qmp.sock" >/dev/null 2>&1 \
    || log "Could not send $1 over QMP"
}

# shutdown asks the guest to power off, and only pulls the plug once it has had VM_STOP_TIMEOUT seconds to do so
shutdown() {
  trap '' TERM INT
  log "Stopping: asking the guest to power off, and waiting up to ${VM_STOP_TIMEOUT}s"
  qmp system_powerdown

  local waited=0
  while kill -0 "$qemu_pid" 2>/dev/null && [ "$waited" -lt "$VM_STOP_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$qemu_pid" 2>/dev/null; then
    log "The guest did not power off within ${VM_STOP_TIMEOUT}s, so QEMU is stopped"
    qmp quit
    sleep 5
    kill -TERM "$qemu_pid" 2>/dev/null || true
  fi
}

main() {
  validate
  install -d -m 0700 "$RUN_DIR"
  trap stop_before_boot TERM INT

  setup_network
  setup_firmware
  rotate_console_log

  local attach_install=0
  if disk_is_blank; then
    if [ -n "$VM_CLOUD_IMAGE" ]; then
      provision_cloud_image
    elif [ -n "$VM_INSTALL_ISO" ]; then
      wait_for_file "$VM_INSTALL_ISO" "the installer"
      attach_install=1
      log "The disk is blank, so the installer $VM_INSTALL_ISO is attached for this boot"
    else
      log "ERROR: the disk is blank and neither VM_CLOUD_IMAGE nor VM_INSTALL_ISO says how to provision it"
      exit 2
    fi
  fi

  local -a args=(
    -name "guest=$VM_NAME,debug-threads=on"
    -machine q35,accel=kvm,usb=off,vmport=off,dump-guest-core=off
    -cpu host
    -smp "$VM_CPUS"
    -nodefaults
    -no-user-config
    -msg timestamp=on
    -qmp "unix:$RUN_DIR/qmp.sock,server=on,wait=off"
    -chardev "socket,id=serial0,path=$RUN_DIR/console.sock,server=on,wait=off,logfile=$STATE_DIR/console.log,logappend=on"
    -serial chardev:serial0
    # A display is attached for installers and rescue only, reachable through the VNC socket
    -device VGA
    -vnc "unix:$RUN_DIR/vnc.sock"
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$STATE_DIR/efivars.fd"
    -device virtio-rng-pci
    # An I/O error pauses the guest instead of reaching its filesystem, so a storage blip is survived by resuming it
    -blockdev "{\"driver\":\"host_device\",\"node-name\":\"disk0-file\",\"filename\":\"$VM_DISK\",\"aio\":\"native\",\"cache\":{\"direct\":true},\"discard\":\"unmap\"}"
    -blockdev '{"driver":"raw","node-name":"disk0","file":"disk0-file","discard":"unmap","detect-zeroes":"unmap"}'
    -device virtio-blk-pci,drive=disk0,bootindex=1,werror=stop,rerror=stop
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no,vhost=on
    -device "virtio-net-pci,netdev=net0,mac=$VM_MAC"
  )

  if [ "$attach_install" = 1 ]; then
    args+=(
      -drive "if=none,id=install,media=cdrom,readonly=on,format=raw,file=$(qemu_path "$VM_INSTALL_ISO")"
      -device ide-cd,bus=ide.0,drive=install,bootindex=2
    )
  fi

  if [ -d "$SEED_DIR" ] && [ -n "$(ls -A "$SEED_DIR")" ]; then
    xorriso -as mkisofs -quiet -V cidata -J -r -o "$RUN_DIR/seed.iso" "$SEED_DIR" >&2
    args+=(
      -drive "if=none,id=seed,media=cdrom,readonly=on,format=raw,file=$RUN_DIR/seed.iso"
      -device ide-cd,bus=ide.1,drive=seed
    )
    log "Seed: the files in $SEED_DIR are attached as a cidata disk"
  fi

  if [ -n "$VM_SHARES" ]; then
    start_shares
    # virtiofsd maps guest memory directly, which only works when that memory is a shared file
    args+=(
      -object "memory-backend-memfd,id=mem0,size=${VM_MEMORY}M,share=on"
      -numa node,memdev=mem0
      "${share_args[@]}"
    )
  fi
  args+=(-m "${VM_MEMORY}M")

  if [ -n "$VM_EXTRA_ARGS" ]; then
    local -a extra_args
    read -ra extra_args <<< "$VM_EXTRA_ARGS"
    args+=("${extra_args[@]}")
  fi

  log "Starting $VM_NAME with ${VM_CPUS} vCPUs and ${VM_MEMORY} MiB of memory"
  "$QEMU" "${args[@]}" &
  qemu_pid=$!
  trap shutdown TERM INT

  # A handled signal interrupts wait before QEMU has exited, so the loop waits again until it really has
  while kill -0 "$qemu_pid" 2>/dev/null; do
    wait "$qemu_pid" || true
  done
  local status=0
  wait "$qemu_pid" || status=$?

  stop_shares
  log "QEMU exited with status $status"
  exit "$status"
}

main "$@"
