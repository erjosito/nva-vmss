# Initialization
rg=cybot
vnet=cybotvnet
subnet=nva
url=https://raw.githubusercontent.com/erjosito/nva-vmss/master/nvaLinux_1nic_noVnet_ScaleSet.json
az group create -n $rg -l westeurope

# Create pool
# Use Batch Explorer


# Deploy template (manual deployment is probably easier)
az group deployment create -n nvadeploy -g $rg --template-uri $url --parameters '{"vmPwd":{"value":"Microsoft123!"}, "vnetName":{"value":"cybotvnet"}, "subnetName":{"value":"nva"}}'

# Alternatively (create VMSS manually)
vmssname=nvavmss2
az vmss create -n $vmssname -g $rg -l westeurope --image UbuntuLTS --admin-username jose --admin-password Microsoft123! --lb "" --vnet-name $vnet --subnet $subnet --nsg nvansg --vm-sku Standard_DS1_v2
scripturl=https://raw.githubusercontent.com/erjosito/nva-vmss/master/linuxNVAconfig-1nic.sh
scriptcmd="chmod 666 ./linuxNVAconfig-1nic.sh && /bin/sh ./linuxNVAconfig-1nic.sh"
az vmss extension set -g $rg --vmss-name $vmssname -n customScript --publisher Microsoft.Azure.Extensions --settings "{'fileUris': ['$scripturl'],'commandToExecute': '$scriptcmd'}"

# Configure NVA external LB (inbound rule for SSH)
lb=nva-slbext
# pip=$(az network public-ip list -g $rg --query [0].name -o tsv)
# az network lb create -g $rg -n $lb --sku Standard --vnet-name $vnet --public-ip-address $pip
# az network lb frontend-ip create
# az network lb address-pool create
# az network lb probe create
frontend=$(az network lb frontend-ip list -g $rg --lb-name $lb -o tsv --query [0].name)
az network lb inbound-nat-pool create -g $rg --lb-name $lb -n inboundSSH --protocol Tcp --frontend-port-range-start 22000 --frontend-port-range-end 22009 --backend-port 22 --frontend-ip-name $frontend
vmssname=$(az vmss list -g $rg --query [0].name -o tsv)
az vmss show -n $vmssname -g $rg --query virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerInboundNatPools
poolid=$(az network lb inbound-nat-pool list -g $rg --lb-name $lb --query [0].id -o tsv)
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerInboundNatPools="[{\"id\":\"$poolid\",\"resourceGroup\": \"$rg\"}]"
az network lb inbound-nat-rule list -g $rg --lb-name $lb -o table

# Configure NVA external LB (outbound rule)
backend=$(az network lb address-pool list -g $rg --lb-name $lb --query [0].name -o tsv)
az network lb outbound-rule create -g $rg --address-pool $backend --frontend-ip-configs $frontend --idle-timeout 5 --lb-name $lb --name outboundRule --outbound-ports 10000 --protocol Tcp
az network lb outbound-rule list -g $rg --lb-name $lb -o table
extbackendid=$(az network lb address-pool list -g $rg --lb-name $lb --query [0].id -o tsv)
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerBackendAddressPools="[{\"id\":\"$extbackendid\"}]"

# Configure NVA internal LB
lb=nva-slbint
# az network lb create -g $rg -n $lb --sku Standard --vnet-name $vnet --subnet $subnet
frontend=$(az network lb frontend-ip list -g $rg --lb-name $lb --query [0].name -o tsv)
backend=$(az network lb address-pool list -g $rg --lb-name $lb --query [0].name -o tsv)
probe=$(az network lb probe list -g $rg --lb-name $lb --query [0].name -o tsv)
az network lb rule create -n haports -g $rg --lb-name $lb --protocol All --frontend-port 0 --backend-port 0 --frontend-ip-name $frontend --backend-pool-name $backend --probe-name $probe
intbackendid=$(az network lb address-pool list -g $rg --lb-name $lb --query [0].id -o tsv)
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerBackendAddressPools="[{\"id\":\"$extbackendid\"},{\"id\":\"$intbackendid\"}]"
az vmss update-instances -g $rg --name $vmssname --instance-ids "*"

# Enable IP forwarding in Azure
az vmss show -n $vmssname -g $rg --query virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].enableIpForwarding -o tsv
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].enableIpForwarding="true"
az vmss update-instances -g $rg --name $vmssname --instance-ids "*"

# Troubleshoot VMSS network config
az vmss show -n $vmssname -g $rg --query virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0]
az vmss list-instances -g $rg -n $vmssname -o table
# LB pools
az vmss show -g $rg -n $vmssname --instance-id 0 --query networkProfileConfiguration.networkInterfaceConfigurations[0].ipConfigurations[0]
az vmss list-instance-public-ips -g $rg -n $vmssname -o table
# Ip forwarding:
az vmss show -g $rg -n $vmssname --instance-id 0 --query networkProfileConfiguration.networkInterfaceConfigurations[0].enableIpForwarding
# NSG (note allowing the traffic in the NSG is critical)
az vmss show -g $rg -n $vmssname --instance-id 0 --query networkProfileConfiguration.networkInterfaceConfigurations[0].networkSecurityGroup


# Default route to LB
rt=batchrt
lb=nva-slbint
vnet=cybotvnet
subnet=batch
nexthop=$(az network lb frontend-ip list -g $rg --lb-name $lb --query [0].privateIpAddress -o tsv)
az network route-table create -g $rg -n $rt -l westeurope
az network route-table route create -g $rg --route-table-name $rt -n default --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address $nexthop
az network vnet subnet update -g $rg --vnet-name $vnet -n $subnet --route-table $rt
az vmss show -g $rg -n $vmssname --instance-id 0 --query networkProfileConfiguration.networkInterfaceConfigurations[0].enableIpForwarding

# Route to Azure Batch mgmt nodes
url1=https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519
url2=$(curl -Lfs "${url}" | grep -Eoi '<a [^>]+>' | grep -Eo 'href="[^\"]+"' | grep "download.microsoft.com/download/" | grep -m 1 -Eo '(http|https)://[^"]+')
prefixes=$(curl -s $url2 | jq -c '.values[] | select(.name | contains ("BatchNodeManagement.WestEurope")) | .properties.addressPrefixes')
prefixes2=$(echo $prefixes | tr -d "[]," | tr -s '"' ' ')
i=0
for prefix in $prefixes2; do i=$((i+1)); az network route-table route create -g $rg --route-table-name $rt -n prefix$i --next-hop-type Internet --address-prefix $prefix; done
az network route-table route list -g $rg --route-table-name $rt -o table

# Route to admin IP addresses
myip=$(curl -s4 ifconfig.co)
az network route-table route create -g $rg --route-table-name $rt -n myIPaddress --next-hop-type Internet --address-prefix "$myip/32"
az network route-table route list -g $rg --route-table-name $rt -o table

# Scale VMSS
az vmss scale -g $rg -n $vmssname --new-capacity 2


# Create job
rg=cybot
account=cybotbatch
key=$(az batch account keys list -n $account -g $rg --query primary -o tsv)
endpoint=$(az batch account show -n $account -g $rg --query accountEndpoint -o tsv)
pool=cybotpool
job=myjob
task=mytask
az batch job create --id $job --pool-id $pool --account-name $account --account-key $key --account-endpoint $endpoint
az batch task create --task-id $task --job-id $job --command-line "curl -s4 https://ifconfig.co" --account-name $account --account-key $key --account-endpoint $endpoint

# Check task output
az batch pool show --pool-id $pool --account-name $account --account-key $key --account-endpoint $endpoint --query "allocationState" -o tsv
az batch task show --job-id $job --account-name $account --account-key $key --account-endpoint $endpoint --task-id $task
