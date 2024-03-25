#!/bin/bash

ROOTFS="/mnt/rootfs"
TARGET_DEVICE=raspberrypi
ARCH="arm64"
DISKIMG="deepin-$TARGET_DEVICE-$TARGET_ARCH.img"
COMPONENTS="main,commercial community"
readarray -t REPOS < ./profiles/sources.list
PACKAGES=`cat ./profiles/packages.txt | grep -v "^-" | xargs | sed -e 's/ /,/g'`

# 在 x86 上构建，需要开qemu
sudo apt update -y
sudo apt-get install -y qemu-user-static binfmt-support mmdebstrap arch-test usrmerge usr-is-merged qemu-system-misc systemd-container

mkdir -p $ROOTFS

# 创建根文件系统
sudo mmdebstrap \
    --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
    --skip=check/empty \
    --include=$PACKAGES \
    --components="main,commercial,community" \
    --architectures=${ARCH} \
    --customize=./profiles/stage-second.sh \
    beige \
    $ROOTFS \
    "${REPOS[@]}"

sudo echo "deepin-$ARCH-$TARGET_DEVICE" | sudo tee $ROOTFS/etc/hostname > /dev/null