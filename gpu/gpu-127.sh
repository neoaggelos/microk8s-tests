#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="1.27"

export CONSTRAINTS="instance-type=Standard_NC6s_v2" # Azure/amd64
# export CONSTRAINTS="instance-type=g3s.4xlarge root-disk=50G" # AWS-amd64
# export CONSTRAINTS="arch=arm64 instance-type=g5g.4xlarge root-disk=50G" # AWS-arm64

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-gpu-127-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" --constraints "${CONSTRAINTS}"

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
juju run --all "
sudo microk8s enable gpu --version v22.9.1
"

while ! juju run --machine 0 'sudo microk8s.kubectl logs -n gpu-operator-resources -l app=nvidia-operator-validator | grep "all validations are successful"'
do
  echo "waiting for validations"
  sleep 5
done
