#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

# Rootfs sizing:
#   debug (default, FULL_ROOTFS unset/0):    1.5G -> resize2fs -M ~200MB, fast flash
#   release (FULL_ROOTFS=1):                 full p14 size (~3.47G), no shrink
if [ "${FULL_ROOTFS:-0}" = "1" ]; then
    ROOTFS_SIZE=3730798592   # mmcblk0p14 = 3643358 blocks * 1024
else
    ROOTFS_SIZE=1610612736   # 1.5G debug
fi

#package rootfs
rm -f rootfs.raw boot.raw
mkdir -p files mnt

# create boot
truncate -s 67108864 boot.raw
mkfs.ext2 boot.raw
mount boot.raw mnt
tar xf alpine_rootfs.tgz -C mnt ./boot --exclude='./boot/linux.efi' --strip-components=2
umount mnt

# create root img
truncate -s $ROOTFS_SIZE rootfs.raw
mkfs.ext4 rootfs.raw
mount rootfs.raw mnt
tar xpf alpine_rootfs.tgz -C mnt --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

umount mnt

# debug only: shrink rootfs to minimum size for fast flashing
if [ "${FULL_ROOTFS:-0}" != "1" ]; then
    resize2fs -M rootfs.raw
fi

# create sparse android images
img2simg rootfs.raw files/alpine_rootfs.bin
img2simg boot.raw files/boot.bin
