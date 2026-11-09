# The stock imager with talos-kernel's signed kernel and the initramfs built against it, for both
# arches: the imager reads them from /usr/install/<arch>/, so a disk image it makes boots the same
# kernel as the installer. COPY only, so neither platform needs emulation.
ARG IMAGER
FROM ${IMAGER}
COPY vmlinuz-amd64 /usr/install/amd64/vmlinuz
COPY initramfs-amd64.xz /usr/install/amd64/initramfs.xz
COPY vmlinuz-arm64 /usr/install/arm64/vmlinuz
COPY initramfs-arm64.xz /usr/install/arm64/initramfs.xz
