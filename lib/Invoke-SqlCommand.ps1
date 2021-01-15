function Invoke-SqlCommand {
	[cmdletbinding()]
	param
	(
  [Parameter(Mandatory = $True)]
  [string]$Server,
  [Parameter(Mandatory = $True)]
  [string]$Database,
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$Credential,
  [Parameter(Mandatory = $True)]
  [Alias('Query', 'SQL')]
  [string]$SqlCommand,
  [switch]$WhatIf
	)
	Write-Verbose "Running $($MyInvocation.MyCommand.Name)"
 Write-Verbose ('Running SQL Command against {0}\{1} as {2}' -f $Server, $Database, $Credential.Username )
	if (!$WhatIf) { Write-Verbose ($SqlCommand | Out-String) }
 
 function openSqlConn {
  $conn.Open()
  $cmd = new-object system.Data.SqlClient.SqlCommand($SqlCommand, $conn)
  $cmd.CommandTimeout = $QueryTimeout
  $ds = New-Object system.Data.DataSet
  $da = New-Object system.Data.SqlClient.SqlDataAdapter($cmd)
  [void]$da.fill($ds)
  $conn.Close()
  $ds.Tables.Rows
 }

 $user = $Credential.UserName
 $password = $Credential.Password
 $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
 $unsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

 if ($WhatIf) { $SqlCommand }
 else {
  $ServerInstance = "$Server "; $Database = "$DataBase"; $ConnectionTimeout = 60; $QueryTimeout = 120
  $conn = new-object System.Data.SqlClient.SQLConnection
  $ConnectionString = "Server={0};Database={1};Connect Timeout={2};User Id=$User;Password=$unsecurePassword" `
   -f $ServerInstance, $Database, $ConnectionTimeout
  $conn.ConnectionString = $ConnectionString
  do {
   Start-Sleep 1
  }
  until ((Test-Connection -ComputerName $Server -Count 1 -Quiet))
  openSqlConn
 }
}