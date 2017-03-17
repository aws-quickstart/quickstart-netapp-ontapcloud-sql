[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [String]$AdminLIF,
    [Parameter(Mandatory=$true)]
    [String]$iScSILIF,
    [Parameter(Mandatory=$true)]
    [String]$SVMName,
    [Parameter(Mandatory=$true)]
    [String]$SVMPwd,
	[Parameter(Mandatory=$true)]
    [decimal]$Capacity
) 

function Connect-ONTAP([String]$AdminLIF, [String]$iScSILIF, [String]$SVMName,[String]$SVMPwd, [decimal]$Capacity)
{
    $ErrorActionPreference = 'Stop'

    try {
    
        Start-Transcript -Path C:\cfn\log\WinEC2_Connect_Storage.ps1.txt -Append
    
        Write-Output "Started @ $(Get-Date)"
        Write-Output "Admin Lif: $AdminLIF"
        Write-Output "iScSI Lif: $iScSiLIF"
        Write-Output "SVM Name : $SVMName"
        Write-Output "SVM Password: $SVMPwd"
        Write-Output "Capacity: $Capacity"

        $AdminLIF= $AdminLIF.Substring($AdminLIF.IndexOf(':')+1)
        $iScSiLIF= $iScSiLIF.Substring($iScSiLIF.IndexOf(':')+1)
        $SVMName = $SVMName.Trim().Replace("-","_")

        Setup-VM

        $IqnName = "awsqsiqn"
        $SecPasswd = ConvertTo-SecureString $SVMPwd -AsPlainText -Force
        $SvmCreds = New-Object System.Management.Automation.PSCredential ("admin", $SecPasswd)
        $VMIqn = (get-initiatorPort).nodeaddress
        #Pad the data Volume size by 10 percent
        $DataVolSize = [System.Math]::Floor($Capacity * 1.1)
        #Log Volume will be one third of data with 10 percent padding
        $LogVolSize = [System.Math]::Floor($Capacity *.37 ) 

		$DataLunSize = $Capacity
		$LogLunSize =  $Capacity *.33
        
        Import-module 'C:\Program Files (x86)\NetApp\NetApp PowerShell Toolkit\Modules\DataONTAP\DataONTAP.psd1'
        
        Connect-NcController $AdminLIF -Credential $SvmCreds -Vserver $SVMName
        Create-NcGroup $IqnName $VMIqn $SVMName
        New-IscsiTargetPortal -TargetPortalAddress $iScSiLIF
        Connect-Iscsitarget -NodeAddress (Get-IscsiTarget).NodeAddress -IsMultipathEnabled $True -TargetPortalAddress $iScSiLIF
    
        Get-IscsiSession | Register-IscsiSession

        New-Ncvol -name sql_data_root -Aggregate aggr1 -JunctionPath $null -size ([string]($DataVolSize)+"g") -SpaceReserve none
        New-Ncvol -name sql_log_root -Aggregate aggr1 -JunctionPath $null -size ([string]($LogVolSize)+"g") -SpaceReserve none

        New-Nclun /vol/sql_data_root/sql_data_lun ([string]$DataLunSize+"gb") -ThinProvisioningSupportEnabled -OsType "windows_2008"
        New-Nclun /vol/sql_log_root/sql_log_lun ([string]$LogLunSize+"gb") -ThinProvisioningSupportEnabled -OsType "windows_2008" 

        Add-Nclunmap /vol/sql_data_root/sql_data_lun $IqnName
        Add-Nclunmap /vol/sql_log_root/sql_log_lun $IqnName

        
        Start-NcHostDiskRescan
        Wait-NcHostDisk -ControllerLunPath /vol/sql_data_root/sql_data_lun -ControllerName $SVMName
        Wait-NcHostDisk -ControllerLunPath /vol/sql_log_root/sql_log_lun -ControllerName $SVMName


        $DataDisk = (Get-Nchostdisk | Where-Object {$_.ControllerPath -like "*sql_data_lun*"}).Disk
        $LogDisk = (Get-Nchostdisk | Where-Object {$_.ControllerPath -like "*sql_log_lun*"}).Disk

        Stop-Service -Name ShellHWDetection
        Set-Disk -Number $DataDisk -IsOffline $False
        Initialize-Disk -Number $DataDisk
        New-Partition -DiskNumber $DataDisk -UseMaximumSize -AssignDriveLetter  | ForEach-Object { Start-Sleep -s 5; $_| Format-Volume -NewFileSystemLabel "NetApp Disk 1" -Confirm:$False -Force }
    
        Set-Disk -number $LogDisk -IsOffline $False
        Initialize-disk -Number $LogDisk
        New-Partition -DiskNumber $LogDisk -UseMaximumSize -AssignDriveLetter | ForEach-Object { Start-Sleep -s 5; $_| Format-Volume -NewFileSystemLabel "NetApp Disk 2" -Confirm:$False -Force}
        Start-Service -Name ShellHWDetection

        Write-Output "Completed @ $(Get-Date)"
        Stop-Transcript

    } 
    catch {
        Write-Output "$($_.exception.message)@ $(Get-Date)"
        $ErrorActionPreference = "Stop"
		exit 1
    }
 }

 

function Create-NcGroup( [String] $VserverIqn, [String] $InisitatorIqn, [String] $Vserver)
{
    $iGroupList = Get-ncigroup
    $iGroupSetup = $False
    $iGroupInitiatorSetup = $False

    #Find if iGroup is already setup, add if not 
    foreach($igroup in $iGroupList)
    {
        if ($igroup.Name -eq $VserverIqn)   
        {
            $iGroupSetup = $True
            foreach($initiator in $igroup.Initiators)
            {
                if($initiator.InitiatorName.Equals($InisitatorIqn))
                {
                    $iGroupInitiatorSetup = $True
                    Write-Output "Found $VserverIqn Iqn is alerady setup on SvM $Vserver with Initiator $InisitatorIqn" 
                    break
                }
            }

            break
        }
    }
    if($iGroupInitiatorSetup -eq $False)
    {
        if ((get-nciscsiservice).IsAvailable -ne "True") { 
                Add-NcIscsiService 
        }
        if ($iGroupSetup -eq $False) {
            new-ncigroup -name $VserverIqn -Protocol iScSi -Type Windows    
        }
        Add-NcIgroupInitiator -name $VserverIqn -Initiator $InisitatorIqn
        Write-Output "Set up $VserverIqn Iqn on SvM $Vserver"
    }

}

function Set-MultiPathIO()
{
    $IsEnabled = (Get-WindowsOptionalFeature -FeatureName MultiPathIO -Online).State

    if ($IsEnabled -ne "Enabled") {

        Enable-WindowsOptionalFeature –Online –FeatureName MultiPathIO
     }
        
}

function Start-ThisService([String]$ServiceName)
{
    
    $Service = Get-Service -Name $ServiceName
    if ($Service.Status -ne "Running"){
        Start-Service $ServiceName
        Write-Output "Starting $ServiceName"
    }
    if ($Service.StartType -ne "Automatic") {
        Set-Service $ServiceName -startuptype "Automatic"
        Write-Output "Setting $ServiceName Service Startup to Automatic"
    }
   
}

 function Setup-VM ()
 {
    Set-MultiPathIO
    Start-ThisService "MSiSCSI"
 }



Connect-ONTAP $AdminLIF $iScSILIF $SVMName $SVMPwd $Capacity




