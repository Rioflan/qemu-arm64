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

set -e

if [ "$EUID" -ne 0 ]; then
  echo >&2 "Please run as root."
  exit 1
fi

PATH=$PATH:/sbin:/usr/sbin
ip=$(which ip)

PARAM_DAEMON=false
PARAM_DAEMON_QEMU=false

### Argument parsing ###
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
  -d | --daemon)
    PARAM_DAEMON=true
    shift
    ;;
  -dq | --daemon-qemu)
    PARAM_DAEMON_QEMU=true
    shift
    ;;
  --mac)
    PARAM_MAC=$2
    shift 2
    ;;
  -m | --memory)
    PARAM_MEMORY=$2
    shift 2
    ;;
  -c | --cores)
    PARAM_CORES=$2
    shift 2
    ;;
  -b=* | --bridge=*)
    PARAM_BRIDGE=true
    DEFAULT_IFACE="${key#*=}"
    shift
    ;;
  -b | --bridge)
    PARAM_BRIDGE=true
    shift
    ;;
  *)
    PARAM_POSITIONAL+=("$1")
    shift
    ;;
  esac
done
set -- "${PARAM_POSITIONAL[@]}" # restore positional parameters

qemu_args=()

### Default arguments ###
function setup_default() {
  DEFAULT_NB_CORES="${PARAM_CORES:-4}"
  DEFAULT_MEMORY="${PARAM_MEMORY:-8G}"
  DEFAULT_BIOS=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd

  qemu_args+=(
    -M virt
    -cpu max
    -m $DEFAULT_MEMORY
    -smp $DEFAULT_NB_CORES
    -bios $DEFAULT_BIOS
    -nographic
  )
}

### Image setup ###
function setup_image() {
  if [ "${#PARAM_POSITIONAL[@]}" -ne 1 ]; then
    echo >&2 "Invalid argument, use: $0 [options] <image>"
    exit 1
  fi

  DEFAULT_IMAGE="${PARAM_POSITIONAL[0]}"

  # Make a copy of image
  USED_IMAGE="/tmp/$(basename $DEFAULT_IMAGE)"
  cp -f $DEFAULT_IMAGE $USED_IMAGE

  qemu_args+=(
    -drive if=none,file=$USED_IMAGE,id=hd0
    -device virtio-blk-device,drive=hd0
  )
}

### Network setup ###
function setup_network() {
  # Find default interface to bridge if no one specified
  if $PARAM_BRIDGE && ! [ "$DEFAULT_IFACE" ]; then
    switch=$(ip route ls | awk '/^default / {
        for(i=0;i<NF;i++) { if ($i == "dev") { print $(i+1); next; } }
        }')
    if [ "${#switch[@]}" -eq 1 ] && [ "${switch[0]}" ]; then
      DEFAULT_IFACE="${switch[0]}"
    else
      echo >&2 "Can't determine interface: $switch"
      echo >&2 "Please specify it with $0 --bridge=<nic to bridge with>"
      exit 1
    fi
  fi

  if ! [ "$PARAM_MAC" ]; then
    #DEFAULT_MAC="${PARAM_MAC:-08:00:27:4D:AF:2F}"
    printf -v DEFAULT_MAC "52:54:%02x:%02x:%02x:%02x" $(($RANDOM & 0xff)) $(($RANDOM & 0xff)) $(($RANDOM & 0xff)) $(($RANDOM & 0xff))
  fi

  # Bridge creation
  # TODO: Not hardcode bridge, fail to create if exists
  DEFAULT_BRIDGE=br0
  ip link add name $DEFAULT_BRIDGE type bridge

  # Add iptables rules
  iptables -I FORWARD -i $DEFAULT_BRIDGE -j ACCEPT

  # Tap creation
  # Get name of newly created TAP device; see https://bbs.archlinux.org/viewtopic.php?pid=1285079#p1285079
  precreationg=$(ip tuntap list | cut -d: -f1 | sort)
  ip tuntap add user $(whoami) mode tap
  postcreation=$(ip tuntap list | cut -d: -f1 | sort)
  DEFAULT_TAP=$(comm -13 <(echo "$precreationg") <(echo "$postcreation"))

  # Network config
  ip addr flush dev $DEFAULT_IFACE
  ip link set dev $DEFAULT_TAP master $DEFAULT_BRIDGE
  ip link set dev $DEFAULT_IFACE master $DEFAULT_BRIDGE
  ip link set dev $DEFAULT_BRIDGE up
  ip link set dev $DEFAULT_BRIDGE up
  ip link set dev $DEFAULT_IFACE up
  dhclient $DEFAULT_BRIDGE

  qemu_args+=(
    -device virtio-net,netdev=net0,mac=$DEFAULT_MAC
    -netdev tap,id=net0,ifname=$DEFAULT_TAP
  )
}

function main() {
  setup_default
  setup_image
  setup_network

  ### Start QEMU ###
  if $PARAM_DAEMON_QEMU; then
    # initrd ?
    qemu-system-aarch64 </dev/null >out.log 2>err.log "${qemu_args[@]}" &
    echo "Write some infos, waiting for qemu to stop"
    wait
  else
    qemu-system-aarch64 "${qemu_args[@]}"
  fi

  ### Cleanup ###
  echo "Cleanup"
  ip 2>/dev/null link delete $DEFAULT_BRIDGE || true
  ip 2>/dev/null link delete $DEFAULT_TAP || true
  dhclient "$DEFAULT_IFACE"
}

if $PARAM_DAEMON; then
  main </dev/null >out.log 2>err.log &
  disown
else
  main
fi
