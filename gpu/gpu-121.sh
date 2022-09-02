#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="1.21"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-gpu-121-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" --constraints 'instance-type=Standard_NC6s_v2'

  trap cleanup EXIT
fi

export JUJU_MODEL="${JUJU_MODEL}"

# 1. install microk8s and enable required addons
juju run --all "
sudo snap install microk8s --classic --channel 1.21
sudo microk8s enable dns
sudo microk8s enable helm3
"

# 2. install nvidia drivers
# 4. install nvidia-container-runtime
juju run --all -- '
sudo apt-get update
sudo apt-get install nvidia-headless-510-server nvidia-utils-510-server -y

curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | \
  sudo apt-key add -
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-container-runtime/$distribution/nvidia-container-runtime.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-runtime.list
sudo apt-get update
sudo apt-get install -y nvidia-container-runtime
'

# 5. configure and restart containerd
juju run --all -- "
echo '
        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia]
          runtime_type = \"io.containerd.runc.v2\"
          [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia.options]
            BinaryName = \"/usr/bin/nvidia-container-runtime\"
' | sudo tee -a /var/snap/microk8s/current/args/containerd-template.toml

sudo snap restart microk8s.daemon-containerd
"

# 6. install GPU operator
juju run --all "
sudo microk8s helm3 repo add nvidia https://nvidia.github.io/gpu-operator
sudo microk8s helm3 install gpu-operator nvidia/gpu-operator \
  --create-namespace -n gpu-operator-resources \
  --set driver.enabled=false,toolkit.enabled=false
"

# 7. wait for validations to complete
while ! juju run --machine 0 'sudo microk8s.kubectl logs -n gpu-operator-resources -l app=nvidia-operator-validator | grep "all validations are successful"'
do
  echo "waiting for validations"
  sleep 5
done
