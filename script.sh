#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo >&2 "Please run as root."
  exit 1
fi

PATH=$PATH:/sbin:/usr/sbin
dependencies=(
  dhclient
  ip
  iptables
  modprobe
  qemu-nbd
  qemu-system-aarch64
  tcpdump
  wget
)
function check_dependencies() {
  local all_installed=true
  for dependency in ${dependencies[@]}; do
    [[ $(type -t $dependency) = "alias" ]] && unalias $dependancy
    if ! command -v $dependency &>/dev/null ]; then
      >&2 echo "$dependency command not found"
      all_installed=false
    fi
  done
  "$all_installed" || exit 1
}; check_dependencies

PARAM_DAEMON=false
PARAM_DAEMON_QEMU=false
PARAM_PUBLIC_KEY=./vm_rsa.pub
PARAM_PRIVATE_KEY=./vm_rsa
PARAM_SAVE_PATH="/tmp/generated.qcow2"

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
-b | --bridge)
    PARAM_BRIDGE=true
    DEFAULT_IFACE=$2
    shift 2
    ;;
  --keys)
    PARAM_PRIVATE_KEY=$2
    PARAM_PUBLIC_KEY="$2.pub"
    shift 2
    ;;
  --public-key)
    PARAM_PUBLIC_KEY=$2
    shift 2
    ;;
  --public-key)
    PARAM_PRIVATE_KEY=$2
    shift 2
    ;;
  --save-path)
    PARAM_SAVE_PATH=$2
    shift 2
    ;;
  *)
    PARAM_POSITIONAL+=("$1")
    shift
    ;;
  esac
done
# restore positional parameters
set -- "${PARAM_POSITIONAL[@]}"

qemu_args=()

### Helper functions ###
function get_dhcp() {
  tcpdump 2>/dev/null -i $1 -Uvvn "((ether host $2) and (udp port 67 or udp port 68))" | grep --line-buffered 'Your-IP' >>/dev/shm/dhcp_address
}

function wait_for_ssh() {
  SECONDS=0
  while [ "$SECONDS" -lt "$1" ]; do
    ips_list="$(sed -nE 's/^[[:space:]]*Your-IP ([0-9]{1,3}(\.[0-9]{1,3}){3})$/\1/p' </dev/shm/dhcp_address)"
    if [ -n "$ips_list" ]; then
      unique_ip="$(sort -u <<<$ips_list)"
      if [ "$(wc -l <<<$unique_ip)" -eq 1 ] && ping >/dev/null -qc1 "$unique_ip"; then
        [ "$(ssh -i $PARAM_PRIVATE_KEY -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=4 root@$unique_ip echo 'OK')" = 'OK' ] && echo $unique_ip && exit 0
      else
        echo >&2 "Multiples ips have been found"
        exit 1
      fi
    fi
    sleep 1
  done
  echo >&2 "SSH timeout"
  exit 1
}

function generate_image() {
  echo "Downloading image ..."
  wget -q --show-progress https://cdimage.debian.org/cdimage/openstack/current-10/debian-10-openstack-arm64.qcow2 -O $PARAM_SAVE_PATH
  [ -f "$PARAM_PUBLIC_KEY" ] || (ssh-keygen -f $PARAM_PRIVATE_KEY -b 4096 -t rsa -N '' && [ -z "$SUDO_USER" ] || chown "$SUDO_USER" "$PARAM_PUBLIC_KEY" "$PARAM_PRIVATE_KEY")

  modprobe nbd
  qemu-nbd -c /dev/nbd0 $PARAM_SAVE_PATH
  rm -rf /tmp/debian && mkdir -p /tmp/debian
  while ! mount 2>/dev/null /dev/nbd0p2 /tmp/debian; do sleep 1; done
  mkdir -p /tmp/debian/root/.ssh
  cat $PARAM_PUBLIC_KEY >>/tmp/debian/root/.ssh/authorized_keys
  umount /tmp/debian
  qemu-nbd >/dev/null -d /dev/nbd0
}

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
  if [ "${#PARAM_POSITIONAL[@]}" -eq 1 ]; then
    DEFAULT_IMAGE="${PARAM_POSITIONAL[0]}"
    # Make a copy of image
    USED_IMAGE="/tmp/$(basename $DEFAULT_IMAGE)"
    cp -f $DEFAULT_IMAGE $USED_IMAGE
  else
    generate_image
    USED_IMAGE=$PARAM_SAVE_PATH
  fi

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
      echo >&2 "Please specify it with $0 --bridge <nic to bridge with>"
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

  echo "Strating qemu ..."
  ### Start QEMU ###
  if $PARAM_DAEMON_QEMU; then
    # initrd ?

    # Begins to filter DHCP packets
    get_dhcp $DEFAULT_BRIDGE $DEFAULT_MAC &
    GET_DHCP_PID=$!
    qemu-system-aarch64 </dev/null >out.log 2>err.log "${qemu_args[@]}" &
    MAX_SSH_UPTIME=120
    if ssh_ip=$(wait_for_ssh $MAX_SSH_UPTIME); then
      echo "Linux ready, you can ssh with"
      echo "ssh -i $PARAM_PRIVATE_KEY root@$ssh_ip"
    else
      echo "Failed to connect by ssh in $MAX_SSH_UPTIME"
    fi
    kill "$GET_DHCP_PID"

    echo "Waiting for the qemu to stop ..."
    wait
  else
    qemu-system-aarch64 "${qemu_args[@]}"
  fi

  ### Cleanup ###
  echo "Qemu stopping"
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
