#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="1.24"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-gpu-124-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" --constraints 'instance-type=Standard_NC6s_v2'

  if [[ "x$CLEANUP" != "xno" ]]; then
    trap cleanup EXIT
  fi
fi

export JUJU_MODEL="${JUJU_MODEL}"

# Install MicroK8s
juju run --all "
sudo snap install microk8s --classic --channel $CHANNEL
"

# Enable GPU addon
# TODO: remove "microk8s addons repo add" once fix is backported
juju run --all "
sudo microk8s addons repo add core https://github.com/canonical/microk8s-core-addons --force
sudo microk8s enable gpu
"

while ! juju run --machine 0 'sudo microk8s.kubectl logs -n gpu-operator-resources -l app=nvidia-operator-validator | grep "all validations are successful"'
do
  echo "waiting for validations"
  sleep 5
done
