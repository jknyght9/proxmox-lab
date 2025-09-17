# Overview

The `setup.sh` script performed several key tasks in building out the lab. This includes:

- Checking requirements
- Generating SSH keys for management
- Verifying your Proxmox setup
- Installing SSH keys on Proxmox
- Running the Proxmox-VE post-installation script
- Building the software defined network
- Building LXC and VM templates
- Generating the Certificate Authority certificates and secrets
- Deploy services
    - Step-CA certificate authority
    - Internal Pihole DNS server
    - External Pihole DNS server
    - Docker swarm
        - 3 node manager
        - Portainer
    - Kasm Workspaces
- Update external PiHole DNS records
- Install new TLS certificates in Proxmox

## Checking Requirements

In this section, the script ensures that `Docker` is installed and running. The script also requires the following packages:

- jq
- sshpass

## Generating SSH Keys

To automate this process, the script will generate new SSH keys for deployment and administration. Both the private `lab-deploy` and public key `lab-deploy.pub` will be stored in the `crypto` folder within this project.

> It is required that the private key stays in the crypto folder until the deployment finished. It is highly recommended that you store the private key in a secured location.

## Verifying Proxmox

In this section, you will need to enter the IP address and root password of your Proxmox server. Here the script will test network connectivity and if the SSH service is running. It will also verify your root login credentials.

## Install SSH Keys

Once the Proxmox server is verified, the newly minted SSH keys will be installed on the server. This is a secure way to run remote commands on the system without the need for passwords.

## Running Proxmox-VE Post-Installation Script

This is a third-party script from Proxmox VE Helper-Scripts [https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install](https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install). This script provides options for managing Proxmox VE repositories, including disabling the Enterprise Repo, adding or correcting PVE sources, enabling the No-Subscription Repo, adding the test Repo, disabling the subscription nag, updating Proxmox VE, and rebooting the system.

## Building a Software Defined Network

Most labs require a separate network for testing purposes. This script creates a simple `Software Defined Network (SDN)` in Proxmox with all required networking services including:

- Default Gateway
- DHCP
- DNS

> This SDN is called **labnet**

## Building LXC and VM Templates

This process is highly reliant on templates to deploy services. During this section, three cloud-init based Linux templates are downloaded from the internet, attached to virtual machines, and converted into templates. These images include:

- Debian 12
- Fedora Cloud 42
- Ubuntu Server 24.04

Additionally, an LXC template is downloaded and installed on the system. This image is:

- Debian 12 Standard

## Generating the Certificate Authority Certificates and Secrets

Almost every Internet service today uses TLS certificates. The purpose of our own internal Certificate Authority is to have the ability to mint new TLS certificates for services that we bring online; typically this is done using the ACME protocol.

This section will generate the root and intermediate certificates, secret keys, passwords, and the Step-CA configuration for later deployment. All of this is created in the `terraform/lxc-step-ca/step-ca` folder.

> It is required that all files stay in this folder until the deployment is finished. It is highly recommended that you store the contents of the **secrets** folder in a secured location post deployment.

## Deploying Services

During this section, we will now begin deploying services in Proxmox. This includes:

### LXC Containers

| Service         | Network      | Purpose                       |
|-----------------|--------------|-------------------------------|
| PiHole Internal | labnet       | Internal DNS                  |
| PiHole External | host network | External DNS                  |
| Step-CA         | host network | Certificate Authority w/ ACME |

### Virtual Machines

| Service      | Network              | Purpose                             |
|--------------|----------------------|-------------------------------------|
| Docker 1,2,3 | host network         | Docker swarm cluster for containers |
| Kasm         | host network, labnet | Kasm workspaces                     |

## Update PiHole DNS Records

Once the services have been deployed, a file named `hosts.json` will contain the hostname and IP address of each service. All external entries will be converted into DNS A recorded and uploaded to the `pihole-external` service.

Additionally, Proxmox's DNS servers will be updated with the new `pihole-external` DNS server IP address. This is required for operations like requesting TLS certificates from the Step-CA server.

> It is highly recommended that your host computers DNS server configuration include the IP address for the pihole-external service. This is required for hostname resolution.

## Install new TLS certificates in Proxmox

Finally, this section will request new TLS certificates from the new Step-CA, using the ACME protocol, for the Proxmox server.