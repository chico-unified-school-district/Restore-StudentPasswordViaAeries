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
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -SecondaryPasswordGroup SomeADPasswordPolicyGroup
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -SecondaryPasswordGroup SomeADPasswordPolicyGroup -WhatIf -Verbose -Debug
=======
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -PrimaryGroup ADGroup1 -SecondaryGroup ADGroup2
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred  -PrimaryGroup ADGroup1 -SecondaryGroup ADGroup2 -WhatIf -Verbose -Debug
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
  # Aeries Server\Database combination
  [Parameter(Mandatory = $True)]
  [ValidateScript( { Test-Connection -ComputerName $_ -Quiet -Count 1 })]
  [string]$SISServer,
  [Parameter(Mandatory = $True)]
  [string]$SISDatabase,
  # Aeries SQL user account with SELECT permission to STU table
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$SISCredential,
  [Parameter(Mandatory = $false)]
  [string]$PrimaryGroup,
  [Parameter(Mandatory = $true)]
  [string]$SecondaryGroup,
  [Alias('wi')]
  [SWITCH]$WhatIf
)

Clear-Host; $error.clear() # Clear Screen and $error
Get-PSSession | Remove-PSSession -WhatIf:$false

# Imported Functions
. .\lib\Add-Log.ps1 # Format log entries
. .\lib\Clear-SessionData.ps1 # Useful function for querying SQL and returning results
. .\lib\Load-Module.ps1
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

function Test-ADSession {
  # AD Domain Controller Session
  if (($script:dc) -and (Test-ComputerSecureChannel -Server $script:dc)) { return }
  Clear-SessionData
  $script:dc = Select-DomainController $DomainControllers
  $adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Set-ADAccountPassword', 'Remove-ADGroupMember', 'Add-ADGroupMember'
  New-ADSession -dc $dc -cmdlets $adCmdLets -cred $ADCredential
}

$usrFromLogQueryBase = Get-Content -Path .\sql\query-log.sql -Raw
$pwResetQuery = Get-Content -Path .\sql\aeries-adpw.sql -Raw

$sisParams = @{
  Server                 = $SISServer
  Database               = $SISDatabase
  Credential             = $SISCredential
  TrustServerCertificate = $true
}
Show-TestRun
'SqlServer' | Load-Module
Write-Host ('Starting {0}. Checks SIS Database everyevery 3 seconds' -f $MyInvocation.MyCommand.Name)
do {
  Test-ADSession
  $studentResets = Invoke-SqlCmd @sisParams -Query $pwResetQuery
  foreach ( $stu in $studentResets ) {
    # Parse Database Query Results
    Write-Verbose ( $stu | Out-String ) # info on the current DB result being processed.
    TrustServerCertificate = $true
    $empId = $stu.ID
    $user = Get-ADUser -LDAPFilter "(employeeid=$empId)"

    if ( $user ) {
      Write-Debug 'process?'
      $sam = $user.samAccountName

      # Get Staff login name
      $usrFromLogQuery = $usrFromLogQueryBase -f $empId
      $logData = (Invoke-SqlCmd @sisParams -Query $usrFromLogQuery)
      # $logData
      if ($logData.USR) {
        # Check USER data and attempt to convert to all UPPER case
        if ( ($logData.USR -is [string]) -and ($null -ne $logData.USR) ) { $staffSamid = $logData.USR.ToUpper() }
      }

      $targetGroup = $SecondaryGroup
      $ADGroupParams = @{
        Identity    = $targetGroup
        Members     = $user.ObjectGUID
        ErrorAction = 'SilentlyContinue'
        Confirm     = $false
        WhatIf      = $WhatIf
      }

      if ([int]$stu.GR -ge 6) {
        Remove-ADGroupMember @ADGroupParams
        Write-Host ('{0} (GR:{1}) removed from {2}' -f $sam, $stu.GR, $targetGroup)
        if (!$WhatIf) { Start-Sleep 15 } # Give AD Time to replicate
        $PasswordNeverExpires = $false
      }
      else {
        $PasswordNeverExpires = $true
      }

      [string]$birthdate = $stu.bd
      $plainPW = $birthdate.split('/ ')[2].substring(2) + $birthdate.split('/ ')[0] + $birthdate.split('/ ')[1]
      Write-Verbose $plainPW
      $pw = (ConvertTo-SecureString $plainPW -AsPlainText -force)
      Set-ADAccountPassword -Identity $user.ObjectGuid -NewPassword $pw -Reset -Confirm:$false -Whatif:$WhatIf
      Add-Log reset ('{0},AD Password Restored by user {1}' -f $sam, $staffSamid)

      # $userParams
      Write-Host "$sam,Set-ADUser Params"
      $adUserParams = @{
        Identity             = $user.ObjectGuid
        Enabled              = $true
        PasswordNeverExpires = $PasswordNeverExpires
        Confirm              = $false
        WhatIf               = $WhatIf
      }
      Set-ADuser @adUserParams

      if ([int]$stu.GR -ge 6) {
        Add-ADGroupMember @ADGroupParams
        Write-Host ('{0} (GR:{1}) Added to {2}' -f $sam, $stu.GR, $targetGroup)
        if (!$WhatIf) { Start-Sleep 5 }
        Set-ADUser -Identity $user.ObjectGuid -Replace @{pwdlastset = 0 } -Confirm:$false -WhatIf:$WhatIf
      }

      Write-Host "$sam,Aeries: Update ADPW field."
      $updateQuery = "UPDATE SUP SET ADPW = `'N`' WHERE SC = {0} and SN = {1}" -f $stu.SC, $stu.SN
      if ($WhatIf) { $updateQuery }
      else { Invoke-Sqlcmd @sisParams -Query $updateQuery }
      Write-Debug 'continue?'
    }
    else {
      TrustServerCertificate = $true
      Write-Verbose ('STU.ID {0} not found' -f $stu.ID)
    }
  } # End Parse Database Query Results
  # Loop every 3 seconds until 11:58pm
  if (!$WhatIf) { Start-Sleep -Seconds 3 }
} until ( $WhatIf -or ( (Get-Date) -ge (Get-Date "11:58pm") ) )

Show-TestRun