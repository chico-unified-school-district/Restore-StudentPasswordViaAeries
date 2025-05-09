#Requires -Version 5.0
<#
	.Synopsis
		This script will reset a user's AD password if the value of [STU].ADPW = 'Y'.
	.DESCRIPTION
		This script queries the SQL DB for changes to the SUP.ADPW field
		and sets and activates or resets AD account passwords.
		After the password is reset the 'ADPW' value is set to 'N'.
	.EXAMPLE
<<<<<<< HEAD
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -Groups SomeADPasswordPolicyGroup
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -Groups SomeADPasswordPolicyGroup -WhatIf -Verbose -Debug
=======
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -Groups 'ADGroup1', 'ADGroup2'
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred  -Groups 'ADGroup1', 'ADGroup2' -WhatIf -Verbose -Debug
>>>>>>> include-usr
	.INPUTS
	.OUTPUTS
	.NOTES
  Requires AD Account running the script have 'Account Operator' permissions in AD
  Aeries user account requires SELECT permission to STU table and UPDATE permission to SUP table.
#>
[cmdletbinding()]
param (
  [Parameter(Mandatory = $True)]
  [Alias('DCs')]
  [string[]]$DomainControllers,
  # PSSession to Domain Controller and Use Active Directory CMDLETS
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$ADCredential,
  [Parameter(Mandatory = $false)]
  [string[]]$ADGroups,
  # Aeries Server\Database combination
  [Parameter(Mandatory = $True)]
  [ValidateScript( { Test-Connection -ComputerName $_ -Quiet -Count 1 })]
  [string]$SISServer,
  [Parameter(Mandatory = $True)]
  [string]$SISDatabase,
  # Aeries SQL user account with SELECT permission to STU table
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$SISCredential,
  [Alias('wi')]
  [SWITCH]$WhatIf
)

function Add-ToPWGroup {
  process {
    $groupErr = $null
    if (!$_.ad) { return $_ }
    if ($_.group) {
      Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, $_.group) -F DarkBlue
      $ADGroupParams = @{
        Identity      = $_.group
        Members       = $_.ad.ObjectGUID
        ErrorAction   = 'SilentlyContinue'
        ErrorVariable = 'groupErr'
        Confirm       = $false
        WhatIf        = $WhatIf
      }
      Add-ADGroupMember @ADGroupParams
      if ($groupErr) {
        Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, $groupErr.ErrorRecord) -F Red
      }
    }
    $_
  }
}

function Complete-Processing {
  process {
    Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, ('=' * 50)) -F Cyan
  }
}

function Get-SiSData ($sqlParams, $query) {
  New-SqlOperation @sqlParams -Query $query | ConvertTo-Csv | ConvertFrom-Csv
}

function Get-ADData {
  process {
    $adParams = @{
      Filter     = "EmployeeId -eq '{0}'" -f $_.sis.ID
      Properties = 'memberof'
    }
    $data = Get-ADuser @adParams
    if (!$data) { Write-Host ('{0},{1},No AD Data found' -f $MyInvocation.MyCommand.Name, $_.sis.ID) -f Green }
    $_.ad = $data
    $_
  }
}

function Get-SiSLogData ($sqlParams, $query) {
  process {
    $sqlVars = "id=$($_.sis.ID)"
    $data = New-SqlOperation @sqlParams -Query $query -Parameters $sqlVars
    if (!$data) {
      Write-Host ('{0},{1},{2},Log data not found' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.sis.SC) -F Red
      return $_
    }
    $_.log = $data
    $_
  }
}

function New-PWObj {
  process {
    [PSCustomObject]@{
      sis   = $_
      ad    = $null
      log   = $null
      group = $null
    }
  }
}

function Remove-FromPWGroup {
  process {
    $groupErr = $null
    if (!$_.ad) { return $_ }
    if ($_.group) {
      Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, $_.group) -F DarkBlue
      $ADGroupParams = @{
        Identity      = $_.group
        Members       = $_.ad.ObjectGUID
        ErrorAction   = 'SilentlyContinue'
        ErrorVariable = 'groupErr'
        Confirm       = $false
        WhatIf        = $WhatIf
      }
      Remove-ADGroupMember @ADGroupParams
      if (!$WhatIf) { Start-Sleep 3 } # Pause for sync
      if ($groupErr) {
        Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, $groupErr.ErrorRecord) -F Red
      }
    }
    $_
  }
}

function Reset-PW {
  process {
    if (!$_.ad) { return $_ }
    $resetParams = @{
      Identity    = $_.ad.ObjectGuid
      NewPassword = (ConvertTo-SecureString $_.sis.BD -AsPlainText -force)
      Reset       = $true
      Confirm     = $false
      WhatIf      = $WhatIf
    }
    $msg = $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, ($_.sis.BD -replace '\d', '*'), $_.log.USR
    Write-Host ('{0},{1},{2},Requested By: {3}' -f $msg) -F DarkBlue
    Set-ADAccountPassword @resetParams
    $_
  }
}

function Set-StuADGroup ($groups) {
  process {
    if (!$_.ad) { return $_ }
    $usersGroups = $_.ad.MemberOf
    foreach ($group in $groups) {
      if ($usersGroups -match $group) {
        $_.group = $group
      }
    }
    $_
  }
}

function Set-PWNeverExpires {
  process {
    if (!$_.ad) { return $_ }
    $expire = if ([int]$_.sis.GR -ge 6) { $false } else { $true }
    if (!$WhatIf) { Start-Sleep 3 } # Give AD Time to replicate
    $adUserParams = @{
      Identity             = $_.ad.ObjectGuid
      Enabled              = $true
      PasswordNeverExpires = $expire
      Confirm              = $false
      WhatIf               = $WhatIf
    }
    $msg = $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, $_.sis.GR, $expire
    Write-Host ('{0},{1},GR:{2},{3}' -f $msg) -F DarkBlue
    Set-ADuser @adUserParams
    $_
  }
}

function Update-SiSPWField ($sqlParams, $query) {
  process {
    $sqlVars = "sc=$($_.sis.SC)", "sn=$($_.sis.SN)"
    $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $query, ($sqlVars -join ',')
    Write-Host ('{0},{1},{2},{3}' -f $msg) -F Blue
    if (!$WhatIf) { New-SqlOperation @sqlParams -Query $query -Parameters $sqlVars }
    $_
  }
}

# ============================================================================================

Import-Module -Name CommonScriptFunctions
Import-Module -Name dbatools

Show-BlockInfo main

if ($WhatIf) { Show-TestRun }

$queryLog = Get-Content -Path .\sql\query-log.sql -Raw
$queryPWReset = Get-Content -Path .\sql\aeries-adpw.sql -Raw
$updatePWSql = "UPDATE SUP SET ADPW = 'N' WHERE SC = @sc and SN = @sn"
$adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Set-ADAccountPassword', 'Remove-ADGroupMember', 'Add-ADGroupMember'

$sisParams = @{
  Server     = $SISServer
  Database   = $SISDatabase
  Credential = $SISCredential
}

'Checking SIS Database every 5 seconds...'
do {
  $sisData = Get-SiSData -sqlParams $sisParams -query $queryPWReset
  if ($sisData) { Connect-ADSession $DomainControllers $ADCredential $adCmdLets }

  $sisData |
    New-PWObj |
      Get-ADData |
        Set-StuADGroup $ADGroups |
          Get-SiSLogData $sisParams $queryLog |
            Remove-FromPWGroup |
              Reset-PW |
                Set-PWNeverExpires |
                  Add-ToPWGroup |
                    Update-SiSPWField $sisParams $updatePWSql |
                      Complete-Processing

  if ($sisData) { Clear-SessionData }
  # Loop every x seconds until 11:58pm
  if (!$WhatIf) { Start-Sleep 5 }
} until ( $WhatIf -or ( (Get-Date) -ge (Get-Date "11:58pm") ) )

if ($WhatIf) { Show-TestRun }