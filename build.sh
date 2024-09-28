#!/bin/bash

set -x
# 不进行交互安装
export DEBIAN_FRONTEND=noninteractive
ROOTFS=`mktemp -d`
TARGET_DEVICE=raspberrypi
ARCH="arm64"
DISKIMG="deepin-$TARGET_DEVICE.img"
IMAGE_SIZE=2048
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

sudo echo "deepin-$TARGET_DEVICE" | sudo tee $ROOTFS/etc/hostname > /dev/null

# 创建磁盘文件
dd if=/dev/zero of=$DISKIMG bs=1M count=$IMAGE_SIZE
sudo fdisk deepin-raspberrypi.img << EOF
n
p
1

+300M
t
c
n
p
2


w
EOF

# 格式化
LOOP=$(sudo losetup -Pf --show $DISKIMG)
sudo mkfs.fat -F32 "${LOOP}p1"
sudo mkfs.ext4 "${LOOP}p2" # 根分区 (/)

TMP=`mktemp -d`
sudo mount "${LOOP}p2" $TMP
sudo cp -r $ROOTFS/* $TMP

sudo mount "${LOOP}p1" $TMP/boot
# 在物理设备上需要添加 cmdline.txt 定义 Linux内核启动时的命令行参数
PTUUID=$(sudo blkid $LOOP | awk -F'PTUUID="' '{print $2}' | awk -F'"' '{print $1}')
echo "console=serial0,115200 console=tty1 root=PARTUUID=$PTUUID-02 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet init=/usr/lib/raspi-config/init_resize.sh" | sudo tee $TMP/boot/cmdline.txt

# 拷贝引导加载程序/GPU 固件等, 从 https://github.com/raspberrypi/firmware/tree/master/boot 官方仓库中拷贝，另外放入了 cmdline.txt 和 config.txt 配置
sudo cp -r firmware/* $TMP/boot

# 编辑分区表
PTUUID=$(sudo blkid $LOOP | awk -F'PTUUID="' '{print $2}' | awk -F'"' '{print $1}')
sudo tee $TMP/etc/fstab << EOF
proc            /proc           proc    defaults          0       0
PARTUUID=$PTUUID-01  /boot           vfat    defaults          0       2
PARTUUID=$PTUUID-02  /               ext4    defaults,noatime  0       1
EOF

sudo mount --bind /dev $TMP/dev
sudo mount -t proc chproc $TMP/proc
sudo mount -t sysfs chsys $TMP/sys
sudo mount -t tmpfs -o "size=99%" tmpfs $TMP/tmp
sudo mount -t tmpfs -o "size=99%" tmpfs $TMP/var/tmp

# 进入 chroot 环境后，更新包列表
sudo chroot $TMP /usr/bin/env bash -e -o pipefail -c "apt update -y"

# 安装树莓派的 raspi-config
sudo chroot $TMP /usr/bin/env bash -e -o pipefail -c "curl http://archive.raspberrypi.org/debian/pool/main/r/raspi-config/raspi-config_20240313_all.deb -o /tmp/raspi-config.deb"
sudo chroot $TMP /usr/bin/env bash -e -o pipefail -c "apt update -y && apt install -y /tmp/raspi-config.deb"
sudo chroot $TMP /usr/bin/env bash -e -o pipefail -c "rm /tmp/raspi-config.deb"

sudo umount -l $TMP
sudo losetup -D $LOOP
sudo rm -rf $TMP $ROOTFS
