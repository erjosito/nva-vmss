# Initialization
rg=cybot
location=westeurope
vnet=cybotvnet
vnetprefix=192.168.0.0/16
nvasubnet=nva
nvasubnetprefix=192.168.1.0/24
batchsubnet=batch
batchsubnetprefix=192.168.2.0/24
pip=nvapip
nsgname=nvansg
extlb=extnvalb
intlb=intnvalb
vmssname=nvavmss
nvasku=Standard_DS1_v2

# Deploy template (manual deployment is probably easier) ** NOT WORKING YET **
#url=https://raw.githubusercontent.com/erjosito/nva-vmss/master/nvaLinux_1nic_noVnet_ScaleSet.json
#az group deployment create -n nvadeploy -g $rg --template-uri $url --parameters '{"vmPwd":{"value":"Microsoft123!"}, "vnetName":{"value":"cybotvnet"}, "subnetName":{"value":"nva"}}'

# Create network infrastructure (int/ext LB, public IP, NSG)   ** WORK IN PROGRESS **
# External LB
az network public-ip create -r $rg -n $pip --sku Standard --allocation-method Static
az network lb create -g $rg -n $extlb --sku Standard --vnet-name $vnet --public-ip-address $pip
az network lb address-pool create -g $rg --lb-name $extlb -n $extlb-backend
az network lb probe create -g $rg --lb-name $extlb -n $extlb-probe --protocol tcp --port 22
# Internal LB
az network lb create -g $rg -n $intlb --sku Standard --vnet-name $vnet --subnet $nvasubnet
az network lb address-pool create -g $rg --lb-name $intlb -n $intlb-backend
az network lb probe create -g $rg --lb-name $intlb -n $intlb-probe --protocol tcp --port 22
# NSG
az network nsg create -g $rg -n $nsgname
az network nsg rule create -g $rg --nsg-name $nsgname -n HTTP --priority 500 --source-address-prefixes '*' --destination-port-ranges 80 --destination-address-prefixes '*' --access Allow --protocol Tcp --description "Allow Port 80"
az network nsg rule create -g $rg --nsg-name $nsgname -n HTTPS --priority 510 --source-address-prefixes '*' --destination-port-ranges 443 --destination-address-prefixes '*' --access Allow --protocol Tcp --description "Allow Port 443"
az network nsg rule create -g $rg --nsg-name $nsgname -n SSH --priority 520 --source-address-prefixes '*' --destination-port-ranges 22 --destination-address-prefixes '*' --access Allow --protocol Tcp --description "Allow Port 22"

# Create RG and vnet/subnets
az group create -n $rg -l $location
az network vnet create -g $rg -n $vnet --address-prefix $vnetprefix
az network vnet subnet create -g $rg --vnet-name $vnet -n $nvasubnet --address-prefixes $nvasubnetprefix
az network vnet subnet create -g $rg --vnet-name $vnet -n $batchsubnet --address-prefixes $batchsubnetprefix

# Get default password from Azure Keyvault. Alternatively, just set to a value (not recommended if you check this code to a git repo)
secretskvname=yourkeyvault
secretname=defaultPassword
password=$(az keyvault secret show -n $secretname --vault-name $secretskvname --query value -o tsv)  # Or alternatively hard code in you example
#password=do_not_do_this_when_checking_in_code

# Deploy VMSS (cloudinit would probably be quicker)
az vmss create -n $vmssname -g $rg -l $location --image UbuntuLTS --admin-username jose --admin-password $password --lb "" --vnet-name $vnet --subnet $nvasubnet --nsg $nsgname --vm-sku $nvasku
scripturl=https://raw.githubusercontent.com/erjosito/nva-vmss/master/linuxNVAconfig-1nic.sh
scriptcmd="chmod 666 ./linuxNVAconfig-1nic.sh && /bin/sh ./linuxNVAconfig-1nic.sh"
az vmss extension set -g $rg --vmss-name $vmssname -n customScript --publisher Microsoft.Azure.Extensions --settings "{'fileUris': ['$scripturl'],'commandToExecute': '$scriptcmd'}"

# Configure NVA external LB (outbound rule, important to do it before the inbound rule, otherwise Intenet access is broken)
frontend=$(az network lb frontend-ip list -g $rg --lb-name $extlb -o tsv --query [0].name)
backend=$(az network lb address-pool list -g $rg --lb-name $extlb --query [0].name -o tsv)
az network lb outbound-rule create -g $rg --address-pool $backend --frontend-ip-configs $frontend --idle-timeout 5 --lb-name $extlb --name outboundRule --outbound-ports 10000 --protocol Tcp
extbackendid=$(az network lb address-pool list -g $rg --lb-name $extlb --query [0].id -o tsv)
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerBackendAddressPools="[{\"id\":\"$extbackendid\"}]"
az vmss update-instances -g $rg --name $vmssname --instance-ids "*"
az network lb outbound-rule list -g $rg --lb-name $extlb -o table

# Configure NVA external LB (inbound rule for SSH)
az network lb inbound-nat-pool create -g $rg --lb-name $extlb -n inboundSSH --protocol Tcp --frontend-port-range-start 22000 --frontend-port-range-end 22009 --backend-port 22 --frontend-ip-name $frontend
vmssname=$(az vmss list -g $rg --query [0].name -o tsv)
az vmss show -n $vmssname -g $rg --query virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerInboundNatPools
poolid=$(az network lb inbound-nat-pool list -g $rg --lb-name $extlb --query [0].id -o tsv)
az vmss update -g $rg -n $vmssname --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].loadBalancerInboundNatPools="[{\"id\":\"$poolid\",\"resourceGroup\": \"$rg\"}]"
az vmss update-instances -g $rg --name $vmssname --instance-ids "*"
az network lb inbound-nat-rule list -g $rg --lb-name $extlb -o table

# Configure NVA internal LB
frontend=$(az network lb frontend-ip list -g $rg --lb-name $intlb --query [0].name -o tsv)
backend=$(az network lb address-pool list -g $rg --lb-name $intlb --query [0].name -o tsv)
probe=$(az network lb probe list -g $rg --lb-name $intlb --query [0].name -o tsv)
az network lb rule create -n haports -g $rg --lb-name $intlb --protocol All --frontend-port 0 --backend-port 0 --frontend-ip-name $frontend --backend-pool-name $backend --probe-name $probe
intbackendid=$(az network lb address-pool list -g $rg --lb-name $intlb --query [0].id -o tsv)
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
# IP forwarding:
az vmss show -g $rg -n $vmssname --instance-id 0 --query networkProfileConfiguration.networkInterfaceConfigurations[0].enableIpForwarding
# NSG (note allowing the traffic in the NSG is critical)
az vmss show -g $rg -n $vmssname --instance-id 0 --query networkProfileConfiguration.networkInterfaceConfigurations[0].networkSecurityGroup

# Default route to LB
rt=batchrt
lb=nva-slbint
vnet=cybotvnet
subnet=batch
nexthop=$(az network lb frontend-ip list -g $rg --lb-name $intlb --query [0].privateIpAddress -o tsv)
az network route-table create -g $rg -n $rt -l westeurope
az network route-table route create -g $rg --route-table-name $rt -n default --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address $nexthop
az network vnet subnet update -g $rg --vnet-name $vnet -n $batchsubnet --route-table $rt
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

#########
# Batch #
#########

rg=cybot
account=cybotbatch
pool=cybotpool

# Create batch account/pool
# Use Azure portal/Batch Explorer (CLI does not seem to support putting pools in vnets)

# Create job
key=$(az batch account keys list -n $account -g $rg --query primary -o tsv)
endpoint=$(az batch account show -n $account -g $rg --query accountEndpoint -o tsv)
job=myjob2
task=mytask
az batch job create --id $job --pool-id $pool --account-name $account --account-key $key --account-endpoint $endpoint
az batch task create --task-id $task --job-id $job --command-line "curl -s4 https://ifconfig.co" --account-name $account --account-key $key --account-endpoint $endpoint

# Check task output
az batch pool show --pool-id $pool --account-name $account --account-key $key --account-endpoint $endpoint --query "allocationState" -o tsv
az batch task show --job-id $job --account-name $account --account-key $key --account-endpoint $endpoint --task-id $task
