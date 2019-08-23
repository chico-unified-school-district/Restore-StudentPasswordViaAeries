#Requires -Version 5.0
<#
	.Synopsis
		This script will reset a user's AD password if the value of [STU].ADPW = 'Y'.
	.DESCRIPTION
		This script queries the SQL DB for changes to the SUP.ADPW field
		and sets and activates or resets AD account passwords.
		After the password is reset the 'ADPW' value is set to 'N'.
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred
	.EXAMPLE
		.\Restore-StudentPasswordViaAeries.PS1 -Dc $dc -ADCred $adCred -SISConn $sisConn -SISCred $sisCred -WhatIf -Verbose -Debug
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
 [SWITCH]$WhatIf
)

Clear-Host; $error.clear() # Clear Screen and $error
Get-PSSession | Remove-PSSession -WhatIf:$false

# AD Domain Controller Session
$adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Set-ADAccountPassword'
$adSession = New-PSSession -ComputerName $DomainController -Credential $ADCredential
Import-PSSession -Session $adSession -Module ActiveDirectory -CommandName $adCmdLets -AllowClobber > $null

# Imported Functions
. .\lib\Add-Log.ps1 # Format log entries
. .\lib\Invoke-SqlCommand.ps1 # Useful function for querying SQL and returning results

$query = Get-Content -Path .\sql\aeries-adpw.sql -Raw
$sisParams = @{
 Server     = $SISServer
 Database   = $SISDatabase
 Credential = $SISCredential
}
do {
 $dbResults = Invoke-SqlCommand @sisParams -Query $query
 foreach ( $dbRow in $dbResults ) {
  # Parse Database Query Results {
  Write-Verbose ( $dbRow | Out-String ) # info on the current DB result being processed.
  $empId = $dbRow.ID
  $user = Get-ADUser -LDAPFilter "(employeeid=$empId)"
  if ( $user ) {
   $sam = $user.samAccountName
   [string]$birthdate = $dbRow.bd
   $plainPW = $birthdate.split('/ ')[2].substring(2) + $birthdate.split('/ ')[0] + $birthdate.split('/ ')[1]
   Write-Verbose $plainPW
   $pw = (ConvertTo-SecureString $plainPW -AsPlainText -force)
   Set-ADAccountPassword -Identity $user.ObjectGuid -NewPassword $pw -Reset -Confirm:$False -Whatif:$WhatIf
   Add-Log reset "$sam,AD Password Restored"
   $setUser = @{
    Identity              = $user.ObjectGuid
    Enabled               = $True
    PasswordNeverExpires  = $True
    ChangePasswordAtLogon = $False
    WhatIf                = $WhatIf
   }
   Write-Verbose "$sam,Set-ADUser Params"
   Set-ADUser @setUser
   Write-Verbose "$sam,Aeries: Update ADPW field."
   $updateQuery = "UPDATE SUP SET ADPW = `'N`' WHERE SC = {0} and SN = {1}" -f $dbRow.SC, $dbRow.SN
   Invoke-SqlCommand @sisParams -SQLCommand $updateQuery -Whatif:$WhatIf
  }
 } # End Parse Database Query Results
 # Loop every 3 seconds until 11:58pm
 if (!$WhatIf) { Start-Sleep -Seconds 3 }
} until ( $WhatIf -or ( (Get-Date) -ge (Get-Date "11:58pm") ) )

Write-Verbose "Tearing down sessions"
Get-PSSession | Remove-PSSession -WhatIf:$false