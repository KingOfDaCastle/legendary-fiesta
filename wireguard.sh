#!/bin/bash
####################################
#Edit line #14 for number of clients #
#####################################
#Client config function
clientgeneration(){
# Generate Client Keys
declare -A keys

counter=1
IP=3
# Change the second number to set up more clients
#clientnumber#
for i in {1..10}; do
  wg genkey | sudo tee /etc/wireguard/keys/client$i\_private.key | wg pubkey > /etc/wireguard/keys/client$i\_public.key
  clientprivatekey[$i]="$(cat /etc/wireguard/keys/client$i\_private.key)"
  clientpublickey[$i]="$(cat /etc/wireguard/keys/client$i\_public.key)"

#Create client config
sudo tee -a /etc/wireguard/client$counter.conf << EOF
[Interface]
Address = 192.168.5.$IP
PrivateKey = ${clientprivatekey[$i]}
ListenPort = 21841
DNS = 192.168.5.1

[Peer]
PublicKey = $publickey
Endpoint = $publicip:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  # add client to server config
sudo tee -a /etc/wireguard/wg0.conf << EOF

[Peer]
PublicKey = ${clientpublickey[$i]}
AllowedIPs = 192.168.5.$IP/32
EOF

((counter++))
((IP++))
done
}


# Grab Public IP of Server
publicip=$(curl icanhazip.com)
# Modifying /etc/sysctl.conf to allow routing through this box
sudo echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf && sudo sysctl -p
sudo apt-get update
sudo apt-get install -y wireguard resolvconf

mkdir /etc/wireguard/keys
# Create Public and Private Keys for Server
wg genkey | sudo tee /etc/wireguard/keys/private.key | wg pubkey > /etc/wireguard/keys/public.key

# Assign the private/public key to a variable
privatekey=$(cat /etc/wireguard/keys/private.key)
publickey=$(cat /etc/wireguard/keys/public.key)

# Find public interface name
interface=$(ip r | grep default | awk '{print $5}')
# Generate Server Configuration File
sudo tee -a /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 192.168.5.1
PrivateKey = $privatekey
ListenPort = 51820
PostUp   = iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $interface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $interface -j MASQUERADE

EOF

#Create client Configs
clientgeneration

#Start the wg0 tunnel
sudo wg-quick up wg0

# Make Wireguard start on boot
sudo systemctl enable wg-quick@wg0.service

#Copy client configs to /tmp
sudo cp /etc/wireguard/client*.conf /tmp

#Get rid of UFW
sudo apt purge ufw -y
sudo apt autoremove ufw -y
sudo apt install iptables -y

#IP tables

for chain in INPUT OUTPUT FORWARD
do
        sudo iptables -P "${chain}" ACCEPT
done
sudo iptables -t filter -F
sudo iptables -t nat -F
sudo iptables -X

# INPUT Chain
sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -p ICMP -j ACCEPT
sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A INPUT -j LOG --log-prefix "iptables input drop: "
#Forward Chain
# sudo iptables -A FORWARD -j LOG --log-prefix "iptables forward drop: "
#OUTPUT chain
sudo iptables -A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A OUTPUT -p icmp -j ACCEPT
sudo iptables -A OUTPUT -p tcp -m multiport --dports 443,53,80 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A OUTPUT -p udp -m multiport --dports 53,123 -j ACCEPT
sudo iptables -A OUTPUT -j LOG --log-prefix "iptables output drop: "
#NAT tables
sudo iptables -t nat -A POSTROUTING -s wg0  -o $interface -j MASQUERADE
# Default Policies
for chain in INPUT OUTPUT FORWARD
do
        sudo iptables -P "${chain}" DROP
done

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | sudo debconf-set-selections
sudo apt install iptables-persistent -y
sudo iptables-save | sudo tee /etc/iptables/rules.v4
sudo reboot
