# These actions will be run at provisioning time
# Most of these commands are ephemeral, so you will probably have to rerun them if you reboot the VM

# Enable IP forwarding
sudo -i sysctl -w net.ipv4.ip_forward=1

###########################
#  Firewall config rules  #
###########################

# SNAT for all traffic
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
