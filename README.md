# MicroK8s End To End Tests

This repository contains end-to-end tests for MicroK8s.

For simplicity, tests are using Juju under the hood and expect a Juju controller that is already bootstrapped. This is to make it easier to run in a variety of settings, clouds, etc.

Tests create a separate Juju model and self-manage all their resources.

## Initialize Juju

For example, to test on Azure, configure your credentials (not shown) and bootstrap a controller:

```bash
juju bootstrap azure/westeurope azure
```

## Run Tests

For example, to run the GPU test:

```bash
juju switch azure
./gpu/gpu-124.sh
```

