#!/bin/bash

set -e

PARAM_PUBLIC_KEY=./vm_rsa.pub
PARAM_PRIVATE_KEY=./vm_rsa

DEFAULT_NB_CORES="${PARAM_CORES:-4}"
DEFAULT_MEMORY="${PARAM_MEMORY:-8G}"
DEFAULT_BIOS=files/QEMU_EFI.fd

# You can get it with:
# wget --quiet -qO- https://nextcloud.rioflan.com/index.php/s/soYLQriaX9gN7tK/download/docker-builder.qcow2.tar.gz | tar xzf -
DEFAULT_IMAGE="docker-builder.qcow2"
USED_IMAGE="/tmp/generated.qcow2"
PARAM_RESIZE="+8G"

qemu_args=()

### Helper functions ###
function send_ssh_command() {
  ssh -i "$PARAM_PRIVATE_KEY" -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=3 -p 5555 root@localhost ${@:1}
}

### Default arguments ###
function setup_default() {
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
  cp -f $DEFAULT_IMAGE $USED_IMAGE

  qemu_args+=(
    -drive if=virtio,file=$USED_IMAGE
  )
}

### Network setup ###
function setup_network() {
  qemu_args+=(
    -device virtio-net,netdev=net0
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:22,hostfwd=tcp:127.0.0.1:2375-:2375
  )
}

function cleanup() {
  echo "Cleaning environment..."
  SECONDS=0
  while kill &>/dev/null -0 $QEMU_PID && [ "$SECONDS" -lt 30 ]; do sleep 1; done
  if kill &>/dev/null -0 $QEMU_PID; then
    kill -9 $QEMU_PID
    echo >&2 "Killing Qemu: $QEMU_PID"
  else
    echo >&2 "Qemu stopped gracefully"
  fi
  echo >&2 "Everything stopped gracefully !"
}

function handle_signal() {
  echo "Handle signal: ${@}"
  # Handling signal
  kill &>/dev/null $GET_DHCP_PID || true
  [ -z "$QEMU_IP" ] || send_ssh_command $QEMU_IP poweroff || true
  cleanup
  exit "$((128 + $1))"
}

_trap() {
  for sig in "$@"; do
    trap "handle_signal $sig" "$sig"
  done
}

_trap INT 2 15

function main() {
  setup_default
  setup_image
  setup_network

  echo "Strating qemu ..."

  ### Start QEMU ###
  qemu-system-aarch64 "${qemu_args[@]}"

  cleanup
}

main </dev/null >out.log 2>err.log &

while ! [ "$(send_ssh_command echo OK)" = 'OK' ]
do
  sleep 5
done
