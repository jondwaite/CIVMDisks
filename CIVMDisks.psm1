# CIVMDisks.psm1
# PowerShell Module to aid VM internal disk manipulation in VMware
# Cloud Director (VCD)
#   Author: Jon Waite, (c)2020 All Rights Reserved
#  License: MIT - See LICENSE.md
#  Version: 0.1 (alpha)
# Homepage: https://github.com/jondwaite/CIVMDisks

# Controller types available in VCD
enum BusTypes {
    ide = 1
    parallel = 3
    sas = 4
    paravirtual = 5
    sata = 6
}

# Internal function to get the highest supported/non-deprecated API version from a Uri:
Function Get-APIVersion {
    Param(
        [Parameter(Mandatory=$true)][Uri]$Uri,
        [Switch]$SkipCertificateCheck
    )

    $APICheckParams = @{
        Uri = "https://$($Uri.Host)/api/versions"
        Headers = @{'Accept'='application/*+xml'}
        Method = 'Get'
    }
    If ($SkipCertificateCheck) {$APICheckParams += @{'SkipCertificateCheck'=$true}}

    Try {
        [xml]$Versions = Invoke-RestMethod @APICheckParams
        $APIVersion = (($Versions.SupportedVersions.VersionInfo | `
            Where-Object { $_.deprecated -eq $false }) | `
            Measure-Object -Property Version -Maximum).Maximum.ToString() + ".0"
        return $APIVersion
    } Catch {
        Write-Error ("Error occurred determining maximum supported API version.")
        return $_.Exception
    }
}

# Internal function to get the SessionId token for the current PowerCLI session:
Function Get-SessionId {
    Param(
        [Parameter(Mandatory=$true)]$VM
    )

    $SessionId = ($global:DefaultCIServers | Where-Object { $_.ServiceUri.Host -eq ([Uri]$VM.Href).Host }).SessionId

    If (!$SessionId) {
        Write-Error ("Could not match supplied VM to a connected VCD instance, exiting.")
        Exit
    }
    return $SessionId
}

# Internal function to retrieve the XML representation of a VM and strip the non VmSpecSection nodes from it:
Function Get-VMDiskXML {
    Param(
        [Parameter(Mandatory=$true)]$VM,
        [Switch]$SkipCertificateCheck
    )

    $APIVersParams = @{'Uri'=$VM.Href}
    if ($SkipCertificateCheck) { $APIVersParams += @{'SkipCertificateCheck'=$true}}
    $APIVersion = Get-APIVersion @APIVersParams
    
    $SessionId = Get-SessionId -VM $VM
    
    $Headers = @{
        'Accept'="application/*+xml;version=$($APIVersion)"
        'x-vcloud-authorization'=$SessionId
    }

    # Get VM details from API
    $VMDetailsParams = @{'Method'='Get';'Headers'=$Headers;'Uri'=$VM.Href}
    if ($SkipCertificateCheck) { $VMDetailsParams += @{'SkipCertificateCheck'=$true}}

    Try {
        [xml]$xmlvm = Invoke-RestMethod @VMDetailsParams
    } Catch {
        Write-Error "Error retrieving VM properties from VCD API, exiting."
        Exit
    }

    # Remove all Child nodes in XML EXCEPT VmSpecSection:
    $RemoveNodes = @()
    $xmlvm.Vm.ChildNodes | ForEach-Object { If ($_.Name -ne 'VmSpecSection') { $RemoveNodes += $_ } }
    $RemoveNodes | ForEach-Object { [void]$xmlvm.Vm.RemoveChild($_) }

    return $xmlvm
}

# Internal function to update the VM with modified XML:
Function Set-VMDiskXML {
    Param(
        [Parameter(Mandatory=$true)]$VM,
        [Parameter(Mandatory=$true)]$BodyXML,
        [int]$TaskTimeout,
        [Switch]$SkipCertificateCheck
    )

    $APIVersParams = @{'Uri'=$VM.Href}
    if ($SkipCertificateCheck) { $APIVersParams += @{'SkipCertificateCheck'=$true}}
    $APIVersion = Get-APIVersion @APIVersParams
    
    $SessionId = Get-SessionId -VM $VM
    
    $Headers = @{
        'Accept'="application/*+xml;version=$($APIVersion)"
        'x-vcloud-authorization'=$SessionId
        'Content-Type'='application/vnd.vmware.vcloud.vm+xml'
    }

    $UpdateVmParams = @{
        Uri = "$($VM.Href)/action/reconfigureVm"
        Body = $BodyXML
        Method = 'Post'
        Headers = $Headers
    }
    if ($SkipCertificateCheck) { $UpdateVmParams += @{'SkipCertificateCheck'=$true}}

    try {
        $VCDTask = Invoke-RestMethod @UpdateVmParams
    } catch {
        Write-Error ("Exception occurred attempting to add disk to VM, exiting.")
        Exit
    }

    if ($VCDtask.Task.href) {           # Task submitted ok and we've asked to wait for it to complete
        $WaitParams = @{TaskHref=$VCDtask.Task.Href; APIVersion=$APIVersion; SessionId=$SessionId; TaskTimeout=$TaskTimeout} 
        if ($SkipCertificateCheck) { $WaitParams += @{'SkipCertificateCheck'=$true}}
        $response = WaitForTask @WaitParams
        return $response
    } else {
        Write-Host -ForegroundColor Red ("Error, request was submitted but no VCD task was returned.")
        return $false
    }
}

# Internal function to wait for a VCD task to complete:
Function WaitForTask {
    Param(
        [Parameter(Mandatory=$true)]$TaskHref,
        [Parameter(Mandatory=$true)]$APIVersion,
        [Parameter(Mandatory=$true)]$SessionId,
        [int]$TaskTimeout = 30,
        [Switch]$SkipCertificateCheck
    )

    $TaskParams = @{
        Uri         = $TaskHref
        Method      = 'Get'
        Headers     = @{'Accept'="application/*+xml;version=$($APIVersion)";'x-vcloud-authorization'=$SessionId}
    }
    if ($SkipCertificateCheck) { $TaskParams += @{'SkipCertificateCheck'=$true}}
        
    Write-Host -ForegroundColor Cyan ("Task submitted successfully.")

    # Give the task a chance to initialize before checking status:
    Start-Sleep -Seconds 5

    :taskcheck While ($TaskTimeout -gt 0) { # Check task status until timeout is exceeeded
        Try { $taskStatus = Invoke-RestMethod @TaskParams }
        Catch { Write-Error ("Error getting task status from VCD API: $($_.Exception.Message), exiting."); Exit }

        switch ($taskStatus.Task.Status) {
            "success" { break taskcheck }
            "running" { Write-Host -ForegroundColor Green "Task Status: Running" }
            "error"   { Write-Error ("Task ended with error, exiting."); Exit }
            "canceled" { Write-Error ("Task was cancelled, exiting."); Exit }
            "aborted" { Write-Error ("Task was aborted, exiting."); Exit }
            "queued"  { Write-Host -ForegroundColor Yellow "Task is queued." }
            "preRunning" { Write-Host -ForegroundColor Yellow "Task is pre-running." }
        }
        # Sleep for 3 seconds before checking status again:
        $TaskTimeout -= 3
        Start-Sleep -Seconds 3
    } # While TaskTimeout > 0

    If ($taskStatus.Task.Status -eq "success") {
        Write-Host -ForegroundColor Green "Operation completed successfully."
        return $true
    } else {
        Write-Host -ForegroundColor Yellow "Task timeout reached (task may still be in progress)"
        return $false
    }
}

# Internal function to process storage size suffix and turn into a disk size in MB:
Function GetDiskSizeMB {
    Param(
        [Parameter(Mandatory=$true)][string]$DiskSize
    )

    [int64]$diskSizeMB = 0
    $unit = $DiskSize.Substring($DiskSize.Length - 1,1)
    $size = $DiskSize.Substring(0,$DiskSize.Length - 1)
    switch ($unit) {
        "M" { $diskSizeMB = [int64]$size }
        "G" { $diskSizeMB = ([float]$size * 1024) }
        "T" { $diskSizeMB = ([float]$size * 1024 * 1024) }
        default { $diskSizeMB = [int64]$diskSize }
    }
    return $diskSizeMB
}

# Get details of the disks attached to a VM
Function Get-CIVMDisk {
    Param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$VM,
        [switch]$SkipCertificateCheck,
        [int]$TaskTimeout = 30
    )

    # Get the VM XML representation from the VCD API:
    $VMDiskXMLParams = @{VM = $VM}
    if ($SkipCertificateCheck) { $VMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $xmlvm = Get-VMDiskXML @VMDiskXMLParams

    $DiskDetails = $xmlvm.Vm.VmSpecSection.DiskSection.DiskSettings

    $DiskDetails | ForEach-Object {

        switch ($_.AdapterType) {
            "1"     { $AdapterName = "ide"}
            "3"     { $AdapterName = "parallel"}
            "4"     { $AdapterName = "sas"}
            "5"     { $AdapterName = "paravirtual"}
            "6"     { $AdapterName = "sata"}
            default { $AdapterName = "unknown"}
        }
        $_.AdapterType = $AdapterName
        $_ | Add-Member -NotePropertyName StorageProfileName -NotePropertyValue $_.StorageProfile.Name
    }
    return $DiskDetails
}

Function Add-CIVMDisk {
    Param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$VM,
        [Parameter(Mandatory=$true)][string]$DiskSize,
        [string]$StorageProfile,
        [BusTypes]$BusType = 'paravirtual',
        [int]$BusId = 0,
        [AllowNull()][Nullable[System.int32]]$UnitId,
        [int64]$iops,
        [switch]$SkipCertificateCheck,
        [int]$TaskTimeout = 30
    )

    # Get the VM XML representation from the VCD API:
    $VMDiskXMLParams = @{VM = $VM}
    if ($SkipCertificateCheck) { $VMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $xmlvm = Get-VMDiskXML @VMDiskXMLParams

    # Convert specified disk size into MB:
    [int64]$SizeMB = GetDiskSizeMB -DiskSize $DiskSize

    # Get Vdc details for this VM and retrieve Storage Profiles available to this Vdc/VM:
    $VMSP = $VM.ExtensionData.StorageProfile
    $OrgVdc = Get-OrgVdc -Org ($VM.Org)
    $VDCSPs = @()
    $OrgVdc | ForEach-Object {
        $_.ExtensionData.vdcStorageProfiles.vdcStorageProfile | ForEach-Object {
            $VDCSPs += $_
        }
    } 

    $DefaultSP = $true
    # Check any user specified Storage Profile and match to available Storage Profiles:
    if ($StorageProfile -eq '*') {
        $DiskSP = $VMSP
    } else {
        if ($StorageProfile) {
            $DiskSP = $VDCSPs | Where-Object { $_.Name -eq $StorageProfile }
            $DefaultSP = $false
            if (!$DiskSP) {
                Write-Error ("Could not match Storage Profile $($StorageProfile) to any accessible Storage Profile available.")
                Write-Host -ForegroundColor Cyan ("Available Storage Profiles are:")
                $VDCSPs | ForEach-Object {
                    Write-Host -ForegroundColor Cyan ($_.Name)
                }
                Exit
            }
        } else { $DiskSP = $VMSP }
    }

    $VmDisks = $xmlvm.Vm.VmSpecSection.DiskSection.DiskSettings | Where-Object {
        (($_.AdapterType -eq $BusType.value__) -and ($_.BusNumber -eq $BusId))
    }

    # Build valid disk slot numbers based on BusType:
    $DiskSlots = @()
    Switch ($BusType) {
        "sata" { $DiskSlots = 0..29 }
        "ide" { $DiskSlots = 0..1 }
        default { $DiskSlots = 0..6 + 8..15 }
    }

    # If we've specified a UnitId that isn't valid for this bus type then give a meaningful error:
    if (($null -ne $UnitId) -and ($UnitId -notin $DiskSlots)) {
        Write-Error ("Cannot use UnitId $($UnitId) on Bus type '$($BusType)', exiting.")
        Write-Host -ForegroundColor Cyan ("Valid Unit Ids for $($BusType) are:")
        $DiskSlots | ForEach-Object { 
            Write-Host -ForegroundColor Cyan ($_)
        }
        Exit
    }

    # If we haven't specified a UnitId, find the first free/empty slot for the new disk:
    if ($null -eq $UnitId) {
        $SlotFound = $false
        Foreach ($slot in $DiskSlots) {
            $Disk = $VmDisks | Where-Object { $_.UnitNumber -eq $slot }
            if (!$Disk) {
                $SlotFound = $true
                $UnitId = $slot
                break
            }
        }
        if (!$SlotFound) {
            Write-Error ("Could not find an available slot to add a disk to bus of type $($BusType) and controller number $($BusId), exiting.")
            Exit
        }
    }
    
    # Check if a disk already exists at the location we're attempting to use for the new disk:
    if ($VmDisks | Where-Object { $_.UnitNumber -eq $UnitId}) {
        Write-Error ("A disk already exists on VM '$($VM.Name)' at UnitId:$($UnitId) on bus:$($BusId) of type '$($BusType)', cannot add a new one, exiting.")
        Exit
    }

    Write-Host ("Adding new disk to VM '$($VM.Name)', size:$($SizeMB)MB type '$($BusType)' on bus:$($BusId) at UnitId:$($UnitId).")

    # Set default namespace on returned XML to www.vmware.com/vcloud/v1.5
    $nsm = New-Object System.Xml.XmlNamespaceManager($xmlvm.NameTable)
    $vcloudNS = "http://www.vmware.com/vcloud/v1.5"
    $nsm.AddNamespace($null,$vcloudNS)

    # Set the 'Modified' attribute on VmSpecSection as being changed:
    [void]$xmlvm.Vm.VmSpecSection.SetAttribute("Modified","true")
    
    # Define XML elements, attributes and values to be created:
    $DSElt = $xmlvm.CreateElement("DiskSettings",$vcloudNS)
    $XMLElts = [ordered]@{
        SizeMb              = $SizeMB
        UnitNumber          = $UnitId
        BusNumber           = $BusId
        AdapterType         = $BusType.value__
        ThinProvisioned     = "true"
        StorageProfile      = $DiskSP
        overrideVmDefault   = if ($DefaultSP) { "false" } else { "true" }
    }
    if ($iops) { $XMLElts += @{iops = $iops} }
    $XMLElts.Keys | ForEach-Object {
        $DSSub = $xmlvm.CreateElement($_,$vcloudNS)
        if ($_ -eq 'StorageProfile') {
            [void]$DSSub.SetAttribute("href",$DiskSP.href)
            [void]$DSSub.SetAttribute("name",$DiskSP.Name)
        } else {
            $DSSubVal = $xmlvm.CreateTextNode($XMLElts.Item($_))
            [void]$DSSub.AppendChild($DSSubVal)    
        }
        [void]$DSElt.AppendChild($DSSub)
    }
    [void]$xmlvm.Vm.VmSpecSection.DiskSection.AppendChild($DSElt)

    # Update the VM with the new disk parameters:
    $SetVMDiskXMLParams = @{VM = $VM;BodyXml = $xmlvm.InnerXml;TaskTimeout = $TaskTimeout}
    if ($SkipCertificateCheck) { $SetVMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $result = Set-VMDiskXML @SetVMDiskXMLParams
    return $result

} # Add-CIVMDisk Function


# Function to remove a hard disk from a VM, deleted hard disks will be permanently removed and the contents lost.
# VM must be powered-off for disks to be removed
Function Remove-CIVMDisk {
    Param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$VM,
        [Parameter(Mandatory=$true)][BusTypes]$BusType,
        [Parameter(Mandatory=$true)][int]$BusId,
        [Parameter(Mandatory=$true)][int]$UnitId,
        [switch]$SkipCertificateCheck,
        [int]$TaskTimeout = 30,
        [switch]$Confirm
    )

    if ($VM.Status -ne 'PoweredOff') {
        Write-Error ("VM '$($VM.Name)' must be powered off before a disk can be removed, exiting."); return $false }
        
    $VMDiskXMLParams = @{VM = $VM}
    if ($SkipCertificateCheck) { $VMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $xmlvm = Get-VMDiskXML @VMDiskXMLParams

    # Check to see if the disk we've specified to remove exists in the VM:
    $DiskToRemove = $xmlvm.Vm.VmSpecSection.DiskSection.DiskSettings | Where-Object {
        (($_.AdapterType -eq $BusType.value__) -and ($_.BusNumber -eq $BusId) -and ($_.UnitNumber -eq $UnitId))
    }
    if (!$DiskToRemove) {
        Write-Error ("Cannot find a disk on VM '$($VM.Name)' with Controller Type '$($BusType)' on Bus:$($BusId) at Unit:$($UnitId), exiting."); return $false }

    Write-Host -ForegroundColor Cyan ("Found a disk on VM '$($VM.Name)', Controller Type '$($BusType)' on Bus:$($BusId) at Unit:$($UnitId).")

    if (!$Confirm) {
        Write-Host -ForegroundColor Green ("Disk will not be removed, re-run this command with the -Confirm switch to actually remove/delete this disk.")
        Exit
    } else {
        Write-Host -ForegroundColor Red ("-Confirm switch was specified, this disk will now be permenantly deleted.")
    }

    # Set the 'Modified' attribute on VmSpecSection as being changed:
    [void]$xmlvm.Vm.VmSpecSection.SetAttribute("Modified","true")

    # Prune the disk to be deleted from the DiskSection XML:
    $DiskNode = $xmlvm.Vm.VmSpecSection.DiskSection.DiskSettings | Where-Object { $_.DiskId -eq $DiskToRemove.DiskId }
    [void]$DiskNode.ParentNode.RemoveChild($DiskNode)

    # Update the VM to remove the disk:
    $SetVMDiskXMLParams = @{VM = $VM;BodyXml = $xmlvm.InnerXml;TaskTimeout = $TaskTimeout}
    if ($SkipCertificateCheck) { $SetVMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $result = Set-VMDiskXML @SetVMDiskXMLParams
    return $result
} # Remove-CIVMDisk Function

Function Update-CIVMDiskSize {
    Param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$VM,
        [Parameter(Mandatory=$true)][BusTypes]$BusType,
        [Parameter(Mandatory=$true)][int]$BusId,
        [Parameter(Mandatory=$true)][int]$UnitId,
        [Parameter(Mandatory=$true)][string]$NewDiskSize,
        [switch]$SkipCertificateCheck,
        [int]$TaskTimeout = 30
    )

    # Get XML representation of this VM's disks
    $VMDiskXMLParams = @{VM = $VM}
    if ($SkipCertificateCheck) { $VMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $xmlvm = Get-VMDiskXML @VMDiskXMLParams

    # Find the disk to be resized:
    $DiskToResize = $xmlvm.Vm.VmSpecSection.DiskSection.DiskSettings | Where-Object {
        (($_.AdapterType -eq $BusType.value__) -and ($_.BusNumber -eq $BusId) -and ($_.UnitNumber -eq $UnitId))
    }

    if (!$DiskToResize) {
        Write-Error ("Could not find a disk on VM '$($VM.Name)' with BusType '$($BusType)' at Bus:$($BusId) and Unit:$($UnitId) to resize, exiting."); return $false }

    $NewSizeMB = GetDiskSizeMB -DiskSize $NewDiskSize

    if ($NewSizeMB -le $DiskToResize.SizeMb) {
        Write-Error ("Can't reduce size of disk on VM '$($VM.Name)' with BusType '$($BusType)' at Bus:$($BusId) and Unit:$($UnitId) from $($DiskToResize.SizeMb)MB to $($NewSizeMB)MB, this command can only increase the size of disks, exiting.")
        return $false
    }

    Write-Host ("Resizing disk on VM '$($VM.Name)' with BusType '$($BusType)' at Bus:$($BusId) and Unit:$($UnitId) from $($DiskToResize.SizeMb)MB to $($NewSizeMB)MB.")

    # Set the 'Modified' attribute on VmSpecSection as being changed:
    [void]$xmlvm.Vm.VmSpecSection.SetAttribute("Modified","true")

    # Set the new size in the XML respresentation of the VM disks:
    $DiskNode = $xmlvm.Vm.VmSpecSection.DiskSection.DiskSettings | Where-Object { $_.DiskId -eq $DiskToResize.DiskId }
    $DiskNode.sizeMb = $NewSizeMB

    # Update the VM to resize the disk:
    $SetVMDiskXMLParams = @{VM = $VM;BodyXml = $xmlvm.InnerXml;TaskTimeout = $TaskTimeout}
    if ($SkipCertificateCheck) { $SetVMDiskXMLParams += @{'SkipCertificateCheck'=$true}}
    $result = Set-VMDiskXML @SetVMDiskXMLParams
    return $result

} # Update-CIVMDiskSize Function

# Export cmdlets from this module to PS:
Export-ModuleMember -Function 'Get-CIVMDisk'
Export-ModuleMember -Function 'Add-CIVMDisk'
Export-ModuleMember -Function 'Update-CIVMDiskSize'
Export-ModuleMember -Function 'Remove-CIVMDisk'