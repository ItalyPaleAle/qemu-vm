# qemu-vm

A container image that runs one KVM virtual machine in its foreground. Stopping the container powers the guest off through ACPI, and the container only kills QEMU if the guest ignores that.

The image has no VM-specific logic. Everything about a VM comes in through the environment variables, devices and mounts below, and a Podman Quadlet `.container` unit is the intended way to run it.

```text
ghcr.io/italypaleale/qemu-vm:v0.1.0
```

Only `v*` tags are published, so a pinned version never changes underneath a host.

## Contract

### Environment

| Variable | Required | Meaning |
| --- | --- | --- |
| `VM_NAME` | yes | Name of the guest, used in logs and as QEMU's process name |
| `VM_CPUS` | yes | Number of vCPUs |
| `VM_MEMORY` | yes | Guest memory, in MiB |
| `VM_MAC` | yes | MAC address of the guest's network card, which the container's interface takes on too |
| `VM_DISK` | no | Raw block device the guest boots from (default `/dev/vm-disk`) |
| `VM_NET_IF` | no | Container interface handed to the guest (default `eth0`) |
| `VM_STOP_TIMEOUT` | no | Seconds the guest gets to power off after a stop, before QEMU is quit (default `120`) |
| `VM_INSTALL_ISO` | no | Installer attached as a CD-ROM, only when the disk is blank |
| `VM_INSTALL_POLL` | no | Seconds between checks for `VM_INSTALL_ISO` while waiting for it (default `10`) |
| `VM_CLOUD_IMAGE_URL` | no | qcow2 or raw image written onto the disk, only when the disk is blank |
| `VM_CLOUD_IMAGE_SHA256` | with the URL | SHA-256 the downloaded image must match |
| `VM_SHARES` | no | Host directories exported over virtiofs, as `tag:/path[,tag:/path]` |
| `VM_EXTRA_ARGS` | no | Extra QEMU arguments, split on whitespace with no quoting |

### Devices and capabilities

| Device | Why |
| --- | --- |
| `/dev/kvm` | Hardware virtualization |
| `/dev/net/tun` | The tap device the guest's network card is attached to |
| `/dev/vhost-net` | Moves the guest's network traffic in the kernel |
| `/dev/vm-disk` (or `VM_DISK`) | The guest's disk, normally a raw block device such as an iSCSI LUN |

The container needs `CAP_NET_ADMIN` to rewire its interface. virtiofsd runs with `--sandbox=none`, since the container is already the sandbox, and needs nothing beyond Podman's default capabilities.

Under SELinux, the container's default `container_t` type can't open a raw block device or `/dev/kvm`, so run it with `--security-opt label=disable` (`SecurityLabelDisable=true` in Quadlet).

### Mounts

| Path | Mode | Contents |
| --- | --- | --- |
| `/vm/state` | rw, persistent | `efivars.fd` (UEFI variables), `console.log` (serial console), and the cloud image while it is being written |
| `/vm/seed` | ro, optional | `meta-data`, `user-data` and `network-config`, attached as a NoCloud `cidata` disk |
| each `VM_SHARES` path | rw | the directory exported to the guest |

### Network

The container's interface `VM_NET_IF` is handed over to the guest whole, using the "tcfilter" model from Kata Containers:
- The interface takes the guest's MAC.
- `tc` mirrors every frame between it and a tap device in both directions.

The container's own network stack never sees a packet, and nothing has to create device nodes at runtime.

The intended setup is a Podman macvlan network with no IPAM, so the guest appears on the LAN with its own MAC and configures its own address:

```ini
# vmlan.network
[Network]
Driver=macvlan
Options=parent=enp1s0
IPAMDriver=none
```

The host can't reach a macvlan guest over the LAN, which is a property of macvlan itself.

### Disk provisioning

At every start, `blkid -p` checks whether the disk is blank: no partition table and no filesystem.

- **With a cloud image:** the image is downloaded into `/vm/state`, verified against `VM_CLOUD_IMAGE_SHA256`, written onto the disk, and deleted again.
- **With an installer:** `VM_INSTALL_ISO` is attached for that boot. If the file doesn't exist yet, the container waits for it.
- **With neither:** the container exits with status 2.

A disk that isn't blank is never touched, and an installer is never attached to it, so an unattended installer can't wipe an installed system.

If the container is stopped while writing a cloud image, the disk is wiped again, so the next start provisions it from scratch instead of booting half an image. To rebuild a guest, stop it, wipe the disk (for example `wipefs -a`), and start it again.

## Operating

| Socket in the container | What it is |
| --- | --- |
| `/run/vm/console.sock` | Serial console. `podman exec -it <name> vm-console` attaches to it, and Ctrl-] detaches |
| `/run/vm/qmp.sock` | QMP monitor. `podman exec <name> vm-qmp <command>` sends one command, such as `cont` or `query-status` |
| `/run/vm/vnc.sock` | VNC display, for installers and rescue |

The serial console is also logged to `/vm/state/console.log`, which is rotated at 20 MiB.

To reach the VNC display from another machine, forward it through the host:

```sh
# On the host
sudo socat TCP-LISTEN:5901,bind=127.0.0.1,fork EXEC:"podman exec -i <name> socat - UNIX-CONNECT:/run/vm/vnc.sock"
# On your machine
ssh -L 5901:127.0.0.1:5901 <host>
```

An I/O error on the disk pauses the guest instead of passing the error on to its filesystem. Once storage is back, resume it with `podman exec <name> vm-qmp cont`. Restarting the container doesn't help, because a paused guest can't answer the power-off request and is only stopped once `VM_STOP_TIMEOUT` runs out.

## Example Quadlet unit

```ini
[Unit]
Description=Example virtual machine
Requires=dev-disk-by\x2did-example.device
After=dev-disk-by\x2did-example.device

[Container]
ContainerName=example
Image=ghcr.io/italypaleale/qemu-vm:v0.1.0
Network=vmlan.network
AddDevice=/dev/kvm
AddDevice=/dev/net/tun
AddDevice=/dev/vhost-net
AddDevice=/dev/disk/by-id/example:/dev/vm-disk
AddCapability=NET_ADMIN
Environment=VM_NAME=example
Environment=VM_CPUS=2
Environment=VM_MEMORY=4096
Environment=VM_MAC=02:00:00:00:00:01
Volume=/var/lib/vms/example:/vm/state
StopTimeout=120
SecurityLabelDisable=true

[Service]
Restart=always
TimeoutStopSec=150

[Install]
WantedBy=multi-user.target
```

## Development

`test/smoke.sh` boots a Fedora Cloud image inside the container on a loop device, checks that the seed reached the guest, and checks that stopping the container powers the guest off cleanly. It needs root and KVM, so CI runs it on GitHub's Linux runners.

```sh
sudo podman build -t localhost/qemu-vm:test -f Containerfile .
sudo ./test/smoke.sh localhost/qemu-vm:test
```

## AI disclosure

This repository was built with AI.
