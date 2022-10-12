
#!/bin/bash
# This file is designed to spin up a Wireguard VPN quickly and easily, 
# including configuring a recursive local DNS server using Unbound
#
# Make sure to change the public/private keys before running the script
# Also change the IPs, IP ranges, and listening port if desired
# iptables-persistent currently requires user input

# add wireguard repo - Not needed for Ubuntu 20.04
#sudo add-apt-repository ppa:wireguard/wireguard -y

# update/upgrade server and refresh repo
sudo apt update -y && apt upgrade -y &&

# install wireguard
sudo apt install wireguard -y  &&

# Generate QR codes for configs.
sudo apt install qrencode -y &&
sleep 5

# Generate keys 
umask 077 && 
mkdir wg && 
mkdir wg/keys &&
mkdir wg/clients &&
wg genkey | tee wg/keys/server_private_key | wg pubkey > wg/keys/server_public_key
wg genkey | tee wg/keys/iphone_private_key | wg pubkey > wg/keys/iphone_public_key && 
wg genkey | tee wg/keys/laptop_private_key | wg pubkey > wg/keys/laptop_public_key

# Create wg0.conf
sleep 5
echo " 
[Interface]
PrivateKey = $(cat wg/keys/server_private_key)
Address = 10.200.200.1/24
ListenPort = 51822
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ens3 -j MASQUERADE; iptables -t nat -A POSTROUTING -s 10.200.200.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ens3 -j MASQUERADE; iptables -t nat -D POSTROUTING -s 10.200.200.0/24 -o eth0 -j MASQUERADE
SaveConfig = true 

#Clients
[Peer] # iphone
PublicKey = $(cat wg/keys/iphone_public_key)
AllowedIPs = 10.200.200.2/32

[Peer] # laptop
PublicKey = $(cat wg/keys/laptop_public_key)
AllowedIPs = 10.200.200.4/32

"| sudo tee /etc/wireguard/wg0.conf

# Do we need a reboot here?
 sleep 5

 sudo wg-quick up wg0 && sudo systemctl enable wg-quick@wg0.service

sleep 2

# enable IPv4 forwarding
sudo sed -i 's/\#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
# negate the need to reboot after the above change
sudo sysctl -p
sudo echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
sleep 5

# Track VPN connection
sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Enable VPN traffic on the listening port: 51822
sudo iptables -A INPUT -p udp -m udp --dport 51822 -m conntrack --ctstate NEW -j ACCEPT

# TCP & UDP recursive DNS traffic
sudo iptables -A INPUT -s 10.200.200.0/24 -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A INPUT -s 10.200.200.0/24 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT

# Allow forwarding of packets that stay in the VPN tunnel
sudo iptables -A FORWARD -i wg0 -o wg0 -m conntrack --ctstate NEW -j ACCEPT

sleep 5

# make firewall changes persistent
sudo apt install iptables-persistent -y &&
sudo systemctl enable netfilter-persistent &&
sudo netfilter-persistent save


# install Unbound DNS
sudo apt install unbound unbound-host -y &&
sleep 2

# download list of DNS root servers
sudo curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache

# create Unbound config files - Delete forwarders based on preference

sleep 5

echo"
forward-zone:
    name: "."
    forward-first: no
    forward-tls-upstream: yes
    forward-addr: 2606:4700:4700::1111@853 # CloudFlare primary
    forward-addr: 2606:4700:4700::1001@853  # CloudFlare secondary
    forward-addr: 2620:fe::fe@853 # Quad9 primary
    forward-addr: 2620:fe::9@853 # Quad9 secondary
    forward-addr: 2001:4860:4860::8888@853 # Google primary
    forward-addr: 2001:4860:4860::8844@853 # Google secondary
    forward-addr: 1.1.1.1@853 # CloudFlare primary
    forward-addr: 1.0.0.1@853 # CloudFlare secondary
    forward-addr: 9.9.9.9@853 # Quad9 primary
    forward-addr: 149.112.112.112@853 # Quad9 secondary
    forward-addr: 8.8.8.8@853 # Google primary
    forward-addr: 8.8.4.4@853 # Google secondary

" | sudo tee /etc/unbound/forward-zone.conf 

sleep 2

echo "
server:
    num-threads: 4
    # enable logs
    verbosity: 1
    # list of root DNS servers
    root-hints: \"/var/lib/unbound/root.hints\"
    # use the root server's key for DNSSEC
    auto-trust-anchor-file: \"/var/lib/unbound/root.key\"
    # respond to DNS requests on all interfaces
    interface: 0.0.0.0
    max-udp-size: 3072
    # IPs authorised to access the DNS Server
    access-control: 0.0.0.0/0                 refuse
    access-control: 127.0.0.1                 allow
    access-control: 10.200.200.0/24             allow
    # not allowed to be returned for public Internet  names
    private-address: 10.200.200.0/24
    #hide DNS Server info
    hide-identity: yes
    hide-version: yes
    # limit DNS fraud and use DNSSEC
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    # add an unwanted reply threshold to clean the cache and avoid, when possible, DNS poisoning
    unwanted-reply-threshold: 10000000
    # have the validator print validation failures to the log
    val-log-level: 1
    # minimum lifetime of cache entries in seconds
    cache-min-ttl: 1800
    # maximum lifetime of cached entries in seconds
    cache-max-ttl: 14400
    prefetch: yes
    prefetch-key: yes
    # Forwarding for tls    
    tls-cert-bundle: \"/etc/ssl/certs/ca-certificates.crt\"
include: /etc/unbound/forward-zone.conf

" | sudo tee /etc/unbound/unbound.conf 

# give root ownership of the Unbound config
sudo chown -R unbound:unbound /var/lib/unbound

sleep 2

# add the localhost name to /etc/hosts
echo "
127.0.0.1 localhost $(hostname)

# IPV6 Conf
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
" | sudo tee /etc/hosts

sleep 1

# disable systemd-resolved
sudo systemctl stop systemd-resolved &&
sudo systemctl disable systemd-resolved

# enable Unbound in place of systemd-resovled
sudo systemctl enable unbound-resolvconf &&
sudo systemctl enable unbound

sleep 5

# config files - Add/Remove these for as many profiles as you like.

echo "[Interface] 
Address = 10.200.200.2/32
PrivateKey = $(cat 'wg/keys/iphone_private_key')
DNS = 10.200.200.1 

[Peer]
PublicKey = $(cat 'wg/keys/server_public_key')
Endpoint = $(curl ifconfig.me):51822
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 21" > wg/clients/iphone.conf

sleep 2

sudo reboot

#  Pull QR Codes with the command qrencode -t ansiutf8 < wg/clients/iphone.conf
