#!/usr/bin/python3

# This script implies two columns, host name and ip address.
# to get neatly aligned columns from excel copy paste use
# awk '{$1 = sprintf("%-20s", $1)} 1' original_file > output_file

managed_hosts_file = 'vms'
output_config_file = '/home/syslq/.ssh/config.d/internal'
private_key = '~/.ssh/id_smesko'
user = 'smesko'


with open(managed_hosts_file) as mhf:
    hosts = mhf.readlines()

for host in hosts:
    host_arr = host.split()
    host = ("Host " + host_arr[0] + "\n" +
            "  HostName " + host_arr[1] + "\n" +
            "  Preferredauthentications publickey \n" +
            "  IdentityFile " + private_key + "\n " +
            " User " + user + "\n" +
            " " + "\n")

    with open(output_config_file, 'a+') as ocf:
        ocf.write(host.lstrip())
        
