#!/bin/bash -x

export ID=${BUILD_NUMBER:-$$}
export CHANNEL="1.28"
export MICROCEPH_CHANNEL="quincy/edge"

cleanup() {
  juju destroy-model "${JUJU_MODEL}" --force --yes
}

# Initialize model
if [[ "x$JUJU_MODEL" = "x" ]]; then
  JUJU_MODEL="${JUJU_MODEL:-microk8s-ceph-$ID}"
  juju add-model "${JUJU_MODEL}"
  juju add-machine -m "${JUJU_MODEL}" --constraints 'mem=4G cores=4 root-disk=40G'

  if [[ "x$CLEANUP" != "xno" ]]; then
    trap cleanup EXIT
  fi
fi

export JUJU_MODEL="${JUJU_MODEL}"

juju run --machine 0 -- '
sudo snap install microceph --channel '"${MICROCEPH_CHANNEL}"'
sudo microceph cluster bootstrap

for l in a b c; do
  loop_file="$(sudo mktemp -p /mnt XXXX.img)"
  sudo truncate -s 1G "${loop_file}"
  loop_dev="$(sudo losetup --show -f "${loop_file}")"
  minor="${loop_dev##/dev/loop}"
  sudo mknod -m 0660 "/dev/sdi${l}" b 7 "${minor}"
  sudo microceph disk add --wipe "/dev/sdi${l}"
done
'

# Install MicroK8s
juju run --machine 0 "
sudo snap install microk8s --classic --channel $CHANNEL
"

# Enable Ceph addon
juju run --machine 0 "
sudo microk8s addons repo add core --force https://github.com/canonical/microk8s-core-addons --reference main
sudo microk8s enable rook-ceph
"

# Connect with microceph
juju run --machine 0 "sudo microk8s connect-external-ceph"

# deploy example pods with 1, 2 and 3 replicas
juju run --machine 0 'sudo microk8s.kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: pvc }
spec: { storageClassName: ceph-rbd, accessModes: [ReadWriteOnce], resources: { requests: { storage: 500Mi } } }
---
apiVersion: v1
kind: Pod
metadata: { name: nginx }
spec:
  volumes: [{ name: pvc, persistentVolumeClaim: { claimName: pvc } }]
  containers: [{ name: nginx, image: nginx, volumeMounts: [{ name: pvc, mountPath: /usr/share/nginx/html }] }]
EOF
'

# wait for volumes and pvcs
while ! juju run --machine 0 "sudo microk8s.kubectl wait --for=condition=ready pod/nginx"
do
  echo 'waiting for pods to come online'
  sleep 5
done
