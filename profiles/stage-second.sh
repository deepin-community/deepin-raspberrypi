#!/bin/sh

rootdir="$1"

# 执行命令的辅助函数
run_in_chroot() {
    systemd-nspawn -D "$rootdir" bash -c "$@"
}

# 设置语言
run_in_chroot "
sed -i -E 's/#[[:space:]]?(en_US.UTF-8[[:space:]]+UTF-8)/\1/g' /etc/locale.gen
sed -i -E 's/#[[:space:]]?(zh_CN.UTF-8[[:space:]]+UTF-8)/\1/g' /etc/locale.gen

locale-gen
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales
"

# 设置root用户密码
run_in_chroot "
echo root:root | chpasswd
"