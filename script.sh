#!/bin/bash

# 1. Download the image (tested with: https://cdimage.debian.org/cdimage/openstack/current-10/debian-10-openstack-arm64.qcow2
# 2. Add keys:
#    sudo modprobe nbd
#    sudo qemu-nbd -c /dev/nbd0 debian-9.9.0-openstack-arm64.qcow2
#    sudo mount /dev/nbd0p2 /mnt
#    ssh-add -L > /mnt/root/.ssh/authorized_keys
#    sudo umount /mnt
#    sudo qemu-nbd -d /dev/nbd0
# 3. Run script

# in order to be able to find brctl
set -e

if [ "$EUID" -ne 0 ]; then
  >&2 echo "Please run as root."
  exit 1
fi

PATH=$PATH:/sbin:/usr/sbin
which ip
ip=$(which ip)

if [ "$#" -eq 1 ]; then
  switch=$(ip route ls | awk '/^default / {
          for(i=0;i<NF;i++) { if ($i == "dev") { print $(i+1); next; } }
         }')
  if [ "${#switch[@]}" -ne 1 ]; then
    >&2 echo "Multiple interfaces are possible: $switch"
    >&2 echo "Please specify it with $0 <image> <nic>"
    exit 1
  else
    DEFAULT_IFACE="${switch[0]}"
  fi
elif [ "$#" -ne 2 ]; then
  >&2 echo "Invalid argument, use: $0 <image> [nic]"
  exit 1
fi

DEFAULT_IMAGE=$1
DEFAULT_IFACE="${2:-$DEFAULT_IFACE}"
DEFAULT_BRIDGE=br0
DEFAULT_TAP=tap0
DEFAULT_MAC=08:00:27:4D:AF:2F
DEFAULT_NB_CORES=4
DEFAULT_RAM=8G
DEFAULT_BIOS=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
USED_IMAGE="/tmp/$(basename $DEFAULT_IMAGE)"

cp -f $DEFAULT_IMAGE $USED_IMAGE
iptables -I FORWARD -i $DEFAULT_BRIDGE -j ACCEPT

ip link add name $DEFAULT_BRIDGE type bridge

# Tap creation
# Get name of newly created TAP device; see https://bbs.archlinux.org/viewtopic.php?pid=1285079#p1285079
precreationg=$(ip tuntap list | cut -d: -f1 | sort)
ip tuntap add user $(whoami) mode tap
postcreation=$(ip tuntap list | cut -d: -f1 | sort)
DEFAULT_TAP=$(comm -13 <(echo "$precreationg") <(echo "$postcreation"))

ip addr flush dev $DEFAULT_IFACE
ip link set dev $DEFAULT_TAP master $DEFAULT_BRIDGE
ip link set dev $DEFAULT_IFACE master $DEFAULT_BRIDGE
ip link set dev $DEFAULT_BRIDGE up
ip link set dev $DEFAULT_BRIDGE up
ip link set dev $DEFAULT_IFACE up
dhclient -v $DEFAULT_BRIDGE

qemu-system-aarch64 -M virt -cpu max \
    -m $DEFAULT_RAM -smp $DEFAULT_NB_CORES \
    -bios $DEFAULT_BIOS \
    -drive if=none,file=$USED_IMAGE,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -device virtio-net,netdev=net0,mac=$DEFAULT_MAC -netdev tap,id=net0,ifname=$DEFAULT_TAP \
    -nographic
    # initrd ?

# Cleanup
echo "Cleanup"
2>/dev/null ip link delete $DEFAULT_BRIDGE || true
2>/dev/null ip link delete $DEFAULT_TAP || true
dhclient $DEFAULT_IFACE
