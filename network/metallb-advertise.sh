#!/bin/bash -x

CHANNEL="${CHANNEL:-1.25}"
SERIES="${SERIES:-focal}"
PROFILE="${PROFILE:-https://raw.githubusercontent.com/ubuntu/microk8s/master/tests/lxc/microk8s.profile}"
ID="${BUILD_NUMBER:-$$}"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-metallb-advertise-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" --constraints 'mem=4G cores=4 root-disk=40G'

  if [[ "x$CLEANUP" != "xno" ]]; then
    trap cleanup EXIT
  fi
fi

export JUJU_MODEL="${JUJU_MODEL}"

# Initialize LXD
juju run --all "
  sudo usermod -a -G lxd ubuntu
  sudo lxd init --auto
  sudo lxc network set lxdbr0 ipv4.address=10.10.10.1/24 ipv4.dhcp.ranges=10.10.10.10-10.10.10.100 ipv6.address=none
  sudo lxc profile create microk8s || true
  curl --silent '${PROFILE}' | sudo lxc profile edit microk8s
"

# Install MicroK8s on one instance, create a loadbalancer service.
juju run --machine 0 -- lxc launch -p default -p microk8s "ubuntu:${SERIES}" microk8s
juju run --machine 0 -- lxc exec microk8s -- bash -x -c "
  while ! snap install microk8s --classic --channel '${CHANNEL}'; do
    echo retry snap installation
    sleep 5
  done
  microk8s enable metallb:10.10.10.200/32

  microk8s kubectl create deploy --image nginx --replicas 3 nginx
  microk8s kubectl expose deploy nginx --type=LoadBalancer --port=80
"

# Launch a second instance, attempt to reach loadbalancer service.
juju run --machine 0 -- lxc launch -p default "ubuntu:${SERIES}" client
while ! juju run --machine 0 -- lxc exec client -- bash -x -c "curl 10.10.10.200 > /dev/null 2> /dev/null"; do
  echo "waiting for LoadBalancer to be reachable"
  sleep 2
done
