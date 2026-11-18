# One KVM virtual machine per container, configured entirely through environment variables
# The base is pinned by digest, so the image only moves to a new AlmaLinux build when this line changes
FROM quay.io/almalinuxorg/almalinux:10@sha256:498b0b31dab82c3be22ac50efb8bf865adce85576495da20de8cedc48b29eec6

LABEL org.opencontainers.image.title="qemu-vm" \
      org.opencontainers.image.description="Runs one KVM virtual machine in the foreground and shuts it down cleanly when the container stops" \
      org.opencontainers.image.source="https://github.com/ItalyPaleAle/qemu-vm"

# The full qemu-kvm package brings the device modules, such as the VGA used for the rescue console, which qemu-kvm-core leaves out
RUN dnf install -y --setopt=install_weak_deps=False \
      qemu-kvm \
      qemu-img \
      edk2-ovmf \
      virtiofsd \
      iproute \
      iproute-tc \
      xorriso \
      socat \
      util-linux \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 vm-console /usr/local/bin/vm-console
COPY --chmod=0755 vm-qmp /usr/local/bin/vm-qmp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
