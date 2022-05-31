function New-PassPhrase {
	[cmdletbinding()]
	param (
  $File1,
  $File2
 )
 $list1 = Get-Content -Path $File1
 $list2 = Get-Content -Path $File2
 $TextInfo = (Get-Culture).TextInfo
 $n1 = $TextInfo.ToTitleCase((Get-Random -InputObject $list1))
 $n2 = $TextInfo.ToTitleCase((Get-Random -InputObject $list2))
 [string]$num = Get-Random -Minimum 10 -Maximum 20
 $n1 + $n2 + $num
}