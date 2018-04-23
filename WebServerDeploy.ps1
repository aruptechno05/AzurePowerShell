param(
[Parameter(Mandatory=$True)]
 [string]
 # VM Name to provide
 $MyVMName
)
Write-Host "Select The Server Name '$MyVMName'";
if ($MyVMName.Length -le 15){
# Connecting the Account
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}
$Location = "uksouth"
$MyResourceGroup = "ResourceGroup"
$ValidateVMName = Get-AzureRmVM -ResourceGroupName $MyResourceGroup -Name $MyVMName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
if(!$ValidateVMName){
#FQDN
$MyFQDN = $MyVMName.ToLower()

# Create Resource Group
$resourceGroup = Get-AzureRmResourceGroup -Name $MyResourceGroup -ErrorAction SilentlyContinue
if(!$resourceGroup){
  Write-Output("Creating resource group " + $MyResourceGroup)
New-AzureRmResourceGroup -Name $MyResourceGroup -Location $Location
} else {
       Write-Output("Using existing resource group " + $MyResourceGroup)
}
# Create Storage Account
$MyStorageAccountName = "webstorage01"
New-AzureRmStorageAccount -ResourceGroupName $MyResourceGroup -Location $Location -Name $MyStorageAccountName -SkuName Standard_LRS -Kind StorageV2  -WarningAction SilentlyContinue

# Create Subnet
$MySubnet = New-AzureRmVirtualNetworkSubnetConfig -Name "webSubnet" -AddressPrefix 10.0.0.0/24 -WarningAction SilentlyContinue

#Create Public IP Address
$MyPublicIP = New-AzureRmPublicIpAddress -Name "webPubIP-001" -ResourceGroupName $MyResourceGroup -DomainNameLabel $MyFQDN -Location $Location `
-AllocationMethod Dynamic -WarningAction SilentlyContinue

#Open a Port
$MyRDP = New-AzureRmNetworkSecurityRuleConfig -Name "RDP-Rule" -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * `
-SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow -WarningAction SilentlyContinue
$MyWebPort1 = New-AzureRmNetworkSecurityRuleConfig -Name "HTTP-Rule" -Protocol Tcp -Direction Inbound -Priority 1010 -SourceAddressPrefix * `
-SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80 -Access Allow -WarningAction SilentlyContinue
$MyWebPort2 = New-AzureRmNetworkSecurityRuleConfig -Name "HTTPS-Rule" -Protocol Tcp -Direction Inbound -Priority 1020 -SourceAddressPrefix * `
-SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443 -Access Allow -WarningAction SilentlyContinue
#Create a Security Group Rule
$MySecurityGroup = New-AzureRmNetworkSecurityGroup -Name "webSG001" -ResourceGroupName $MyResourceGroup -Location $Location `
-SecurityRules $MyRDP,$MyWebPort1,$MyWebPort2 -WarningAction SilentlyContinue

#Create Nework
$MyVnet = New-AzureRmVirtualNetwork -Name "webNetwork" -ResourceGroupName $MyResourceGroup `
        -Location $Location -AddressPrefix 10.0.0.0/16 -Subnet $MySubnet -WarningAction SilentlyContinue

#Create New Interface
$MyNic = New-AzureRmNetworkInterface -Name "webNIC-001" -ResourceGroupName $MyResourceGroup -Location $Location `
 -SubnetId $MyVnet.Subnets[0].Id -PublicIpAddressId $MyPublicIP.Id -NetworkSecurityGroupId $MySecurityGroup.Id -WarningAction SilentlyContinue



#Create OS Disk
$MyStorageAccount = Get-AzureRmStorageAccount -Name:$MyStorageAccountName -ResourceGroupName:$MyResourceGroup -WarningAction SilentlyContinue
$MyOSDisk = $MyVMName + "_OS"
$MyOSDiskVHDUri = $MyStorageAccount.PrimaryEndpoints.Blob.ToString() + "vhd/" + $MyOSDisk + ".vhd"

$VMLocalAdminUser = 'LocalAdminUser'
$VMLocalAdminSecurePassword = ConvertTo-SecureString 'myPassword123' -AsPlainText -Force
$VMCredential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword);
 
# Create Config Object
$MyOwnVm = New-AzureRmVMConfig -VMName $MyVMName -VMSize "Standard_B1ms" -WarningAction SilentlyContinue


# OS Settings of VM
$MyOwnVm = Set-AzureRmVMOperatingSystem -VM $MyOwnVm -Windows -ComputerName $MyFQDN -Credential $VMCredential -ProvisionVMAgent -EnableAutoUpdate -WarningAction SilentlyContinue

#Define Image
$MyOwnVm = Set-AzureRmVMSourceImage -VM $MyOwnVm -PublisherName "MicrosoftWindowsServer" `
-Offer "WindowsServer" -Skus "2012-R2-Datacenter" -Version "latest" -WarningAction SilentlyContinue

#Attach Disk
$MyOwnVm = Set-AzureRmVMOSDisk -VM $MyOwnVm -Name $MyOSDisk -VhdUri $MyOSDiskVHDUri -CreateOption "FromImage" -WarningAction SilentlyContinue

#add Nic Card
$MyOwnVm = Add-AzureRmVMNetworkInterface -VM $MyOwnVm -Id $MyNic.Id -WarningAction SilentlyContinue


#Create VM
New-AzureRmVM -ResourceGroupName $MyResourceGroup -Location $Location -VM $MyOwnVm -WarningAction SilentlyContinue

# Install IIS
$timeout = new-timespan -Minutes 30
$sw = [diagnostics.stopwatch]::StartNew()
while ($sw.elapsed -lt $timeout){
$ValidateVMName = Get-AzureRmVM -ResourceGroupName $MyResourceGroup -Name $MyVMName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue    
    if(!$ValidateVMName){
        start-sleep -seconds 50
    } else {
$PublicSettingsIIS = '{"commandToExecute":"powershell Add-WindowsFeature Web-Server"}'
Set-AzureRmVMExtension -ExtensionName "IIS" -ResourceGroupName $MyResourceGroup -VMName $MyOwnVm `
  -Publisher "Microsoft.Compute" -ExtensionType "CustomScriptExtension" -TypeHandlerVersion 1.4 `
  -SettingString $PublicSettingsIIS -Location $Location -WarningAction SilentlyContinue
  start-sleep -seconds 50
  Write-Output ("Please connect to '$MyFQDN'.uksouth.cloudapp.azure.com. Your machine is ready")
break    
    }
}
} else {
    Write-Output ("The Provided VM name '$MyVMName' is already in use. Please use another one")
}
    } else {
      Write-Output ("The Provided VM name '$MyVMName' is more than Fifteen Character. Please use another one")  
    }
