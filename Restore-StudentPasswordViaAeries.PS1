#Requires -Version 5.0
<#
	.Synopsis
		This script will reset a user's AD password if the value of [STU].ADPW = 'Y'.
	.DESCRIPTION
		This script queries the SQL DB for changes to the SUP.ADPW field
		and sets and activates or resets AD account passwords.
		After the password is reset the 'ADPW' value is set to 'N'.
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -SecondaryPasswordGroup SomeADPasswordPolicyGroup
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -SecondaryPasswordGroup SomeADPasswordPolicyGroup -WhatIf -Verbose -Debug
	.INPUTS
	.OUTPUTS
	.NOTES
  Requires AD Account running the script have 'Account Operator' permissions in AD
  Aeries user account requires SELECT permission to STU table and UPDATE permission to SUP table.  
#>
[cmdletbinding()]
param (
 [Parameter(Mandatory = $True)]
 [Alias('DC')]
 [ValidateScript( { Test-Connection -ComputerName $_ -Quiet -Count 1 })]
 [string]$DomainController,
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
 [string]$PrimaryPasswordGroup,
 [Parameter(Mandatory = $true)]
 [string]$SecondaryPasswordGroup,
 [SWITCH]$WhatIf
)

Clear-Host; $error.clear() # Clear Screen and $error
Get-PSSession | Remove-PSSession -WhatIf:$false

# Imported Functions
. .\lib\Add-Log.ps1 # Format log entries
. .\lib\Invoke-SqlCommand.ps1 # Useful function for querying SQL and returning results

# AD Domain Controller Session
Add-Log session ('{0} connected to {1}' -f $ADCredential.UserName, $DomainController)
$adSession = New-PSSession -ComputerName $DomainController -Credential $ADCredential
$adCmdLets = @(
 'Get-ADUser'
 'Set-ADUser'
 'Set-ADAccountPassword'
 'Remove-ADPrincipalGroupMembership'
 'Add-ADPrincipalGroupMembership'
)
Import-PSSession -Session $adSession -Module ActiveDirectory -CommandName $adCmdLets -AllowClobber > $null

$query = Get-Content -Path .\sql\aeries-adpw.sql -Raw
$sisParams = @{
 Server     = $SISServer
 Database   = $SISDatabase
 Credential = $SISCredential
}
do {
 $studentResets = Invoke-SqlCommand @sisParams -Query $query
 foreach ( $stu in $studentResets ) {
  # Parse Database Query Results
  Write-Verbose ( $stu | Out-String ) # info on the current DB result being processed.
  $empId = $stu.ID
  $user = Get-ADUser -LDAPFilter "(employeeid=$empId)"

  if ( $user ) {
   Write-Debug 'process?'
   $sam = $user.samAccountName

   if ($stu.GR -ge 6){
    $targetGroup = $SecondaryPasswordGroup
    $removeParams = @{
     Identity = $user.ObjectGUID
     MemberOf = $targetGroup
     ErrorAction = 'SilentlyContinue'
     Confirm = $false
     WhatIf = $WhatIf
    }
    Remove-ADPrincipalGroupMembership @removeParams
    Write-Verbose ('{0} (GR:{1}) removed from {2}' -f $sam, $stu.GR, $targetGroup)
    Start-Sleep 15 # Give AD Time to replicate
    $PasswordNeverExpires = $false
   } else {
    $PasswordNeverExpires = $true
   }

   [string]$birthdate = $stu.bd
   $plainPW = $birthdate.split('/ ')[2].substring(2) + $birthdate.split('/ ')[0] + $birthdate.split('/ ')[1]
   Write-Verbose $plainPW
   $pw = (ConvertTo-SecureString $plainPW -AsPlainText -force)
   Set-ADAccountPassword -Identity $user.ObjectGuid -NewPassword $pw -Reset -Confirm:$false -Whatif:$WhatIf
   Add-Log reset ('{0},AD Password Restored' -f $sam)

   # $userParams
   Write-Verbose "$sam,Set-ADUser Params"
   Set-ADuser -Identity $user.ObjectGuid -Enabled:$True -PasswordNeverExpires:$PasswordNeverExpires -Confirm:$false -WhatIf:$WhatIf

   if ($stu.GR -ge 6){
    Add-ADPrincipalGroupMembership -Identity $user.ObjectGUID -MemberOf $targetGroup -Confirm:$False -WhatIf:$WhatIf
    Write-Verbose ('{0} (GR:{1}) added to {2}' -f $sam, $stu.GR, $targetGroup)
    Start-Sleep 5
    Set-ADUser -Identity $user.ObjectGuid -Replace @{pwdlastset=0} -Confirm:$false -WhatIf:$WhatIf
   }

   Write-Verbose "$sam,Aeries: Update ADPW field."
   $updateQuery = "UPDATE SUP SET ADPW = `'N`' WHERE SC = {0} and SN = {1}" -f $stu.SC, $stu.SN
   Invoke-SqlCommand @sisParams -SQLCommand $updateQuery -Whatif:$WhatIf
   Write-Debug 'continue?'
  } else {
   Write-Verbose ('STU.ID {0} not found' -f $stu.ID)
  }
 } # End Parse Database Query Results
 # Loop every 3 seconds until 11:58pm
 if (!$WhatIf) { Start-Sleep -Seconds 3 }
} until ( $WhatIf -or ( (Get-Date) -ge (Get-Date "11:58pm") ) )

Write-Verbose "Tearing down sessions"
Get-PSSession | Remove-PSSession -WhatIf:$false