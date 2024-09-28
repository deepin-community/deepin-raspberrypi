#!/bin/bash

set -x
# 不进行交互安装
export DEBIAN_FRONTEND=noninteractive
BUILD_TYPE="$1"
ROOTFS=`mktemp -d`
TARGET_DEVICE=raspberrypi
ARCH="arm64"
DISKIMG="deepin-$TARGET_DEVICE.img"
IMAGE_SIZE=$( [ "$BUILD_TYPE" == "desktop" ] && echo 12288 || echo 2048 )
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
    --include=$PACKAGES \
    --components="main,commercial,community" \
    --architectures=${ARCH} \
    --customize=./profiles/stage-second.sh \
    beige \
    $ROOTFS \
    "${REPOS[@]}"

sudo echo "deepin-$ARCH-$TARGET_DEVICE" | sudo tee $ROOTFS/etc/hostname > /dev/null

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
sudo cp -r firmware/boot/* $TMP/boot
sudo cp -r firmware/modules/* $TMP/lib/modules/

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

function run_command_in_chroot()
{
    rootfs="$1"
    command="$2"
    sudo chroot "$rootfs" /usr/bin/env bash -e -o pipefail -c "$command"
}

# 安装树莓派的 raspi-config
run_command_in_chroot "$TMP" "curl http://archive.raspberrypi.org/debian/pool/main/r/raspi-config/raspi-config_20240521_all.deb -o /tmp/raspi-config.deb"
run_command_in_chroot "$TMP" "export DEBIAN_FRONTEND=noninteractive && \
    apt update -y && apt install -y \
    /tmp/raspi-config.deb && \
    rm /tmp/raspi-config.deb"

# 进入根文件系统，生成 systemd 服务文件
sudo tee $TMP/etc/systemd/system/raspi-config.service << EOF
[Unit]
Description=Run raspi-config at boot
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/raspi-config
StandardOutput=tty
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# 启用 raspi-config 服务
run_command_in_chroot $TMP "systemctl enable raspi-config.service"

if [[ "$BUILD_TYPE" == "desktop" ]];
then
    run_command_in_chroot $TMP "export DEBIAN_FRONTEND=noninteractive &&  apt update -y && apt install -y \
        deepin-desktop-environment-core \
        deepin-desktop-environment-base \
        deepin-desktop-environment-cli \
        deepin-desktop-environment-extras \
        firefox \
        deepin-installer \
        deepin-installer-timezones"

    # 设置安装器
    sudo install -D ./profiles/deepin-installer.conf $TMP/etc/deepin-installer/deepin-installer.conf
    echo -n 'apt_source_deb="' | sudo tee -a $TMP/etc/deepin-installer/deepin-installer.conf
    echo "deb https://community-packages.deepin.com/beige/ beige main commercial community" | sudo tee -a $TMP/etc/deepin-installer/deepin-installer.conf
    sudo ln -s ../deepin-installer-first-boot.service $TMP/usr/lib/systemd/system/multi-user.target.wants/deepin-installer-first-boot.service
    sudo rm $TMP/usr/lib/systemd/system/deepin-installer.service

fi

sudo umount -l $TMP
sudo losetup -D $LOOP
sudo rm -rf $TMP $ROOTFS
