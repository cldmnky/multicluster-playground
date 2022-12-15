# Multi cluster Playground

## Requirements

* calicoctl must be installed
* kubectl must be installed
* kind must be installed
* For mac, use colima for running the demo. (brew install colima && colima start --cpu 4 -m 12)


## Running

* Just run `make` to setup the environment.

> This will setup a three node `kind` cluster, with calico cni and metallb installed.

* Then run: `make setup-skupper` to install and setup `skupper` (including links)

To test: `make skupper-dashboard` and `make kuard-web` 

## Architecture

This demo will setup a three node cluster with an ingress in the "central" cluster, the dc1 and dc2 clusters will be connected using skupper to the central cluster.

The central cluster will setup an ingress for the skupper service and load balance to the dc1 and dc2 cluster.

<img width="584" alt="image" src="https://user-images.githubusercontent.com/1163462/207819137-cda5cb1e-b3e7-4bc2-a5fe-41221fd15746.png">


