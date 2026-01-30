# Photon server support

*This is a work in progress; it is being checked in because it is easier to manage that way. It is independent of the standard Android and iOS deployments.*

## Design

The basic model is that the photon server runs on a VM in a VMSS. When the VM is first created, it downloads all the software it needs and builds a full photon database, with a load balancer IP in front of it, accessible only from Front Door.

## Instructions

Deployment of the photon server works as follows.

- Create and source a config file

    - FIXME: document it xxx

- Upload the docker image.

    ~~~bash
    bash scripts/photonbuild.sh
    ~~~

- Load the base infrastructure

    ~~~bash
    bash scripts/photonbase.sh
    ~~~

- Set up the VMSS

    ~~~bash
    bash scripts/photonvm.sh
    ~~~

## Missing work

- There is no way for incoming traffic to arrive at the photon server. That can be resolved by adding some Front Door configuration

- There is no upgrade or rebuild process; in theory, adding a new VMSS instance should work for upgrade, but it has had zero testing

- Logging and metrics are limited

- Testing is very limited