<script>
winrm quickconfig -q & winrm set winrm/config/service '@{AllowUnencrypted="false"}'
</script>
<powershell>
cmd.exe /c winrm set "winrm/config/service/auth" '@{Basic="false"}'
cmd.exe /c winrm set "winrm/config/service/auth" '@{Certificate="true"}'
Set-ExecutionPolicy -ExecutionPolicy Bypass
Set-NetFirewallRule -DisplayName 'Windows Remote Management (HTTP-In)' -Action Block -PassThru | Select -Property DisplayName, Profile, Action

if("${username}" -eq "administrator") {
    $admin = [adsi]("WinNT://./administrator, user")
    $admin.psbase.invoke("SetPassword", "${password}")
} else {
    $Password = ConvertTo-SecureString -AsPlainText "${password}" -Force
    New-LocalUser "${username}" -Password $Password
    Add-LocalGroupMember -Group "Administrators" -Member "${username}"
}

</powershell>

#####################################################

#Requires -Version 3.0

# Configure a Windows host for remote management with Ansible
# -----------------------------------------------------------

# Support -Verbose option
[CmdletBinding()]

Param (
[string]$SubjectName = $env:COMPUTERNAME,
[int]$CertValidityDays = 1095,
[switch]$SkipNetworkProfileCheck,
$CreateSelfSignedCert = $true,
[switch]$ForceNewSSLCert,
[switch]$EnableCredSSP
)

Function Write-Log
{
$Message = $args[0]
Write-EventLog -LogName Application -Source $EventSource -EntryType Information -EventId 1 -Message $Message
}

Function Write-VerboseLog
{
$Message = $args[0]
Write-Verbose $Message
Write-Log $Message
}

Function Write-HostLog
{
$Message = $args[0]
Write-Output $Message
Write-Log $Message
}

Function New-LegacySelfSignedCert
{
Param (
[string]$SubjectName,
[int]$ValidDays = 1095
)

$hostnonFQDN = $env:computerName
$hostFQDN = [System.Net.Dns]::GetHostByName(($env:computerName)).Hostname
$SignatureAlgorithm = "SHA256"

$name = New-Object -COM "X509Enrollment.CX500DistinguishedName.1"
$name.Encode("CN=$SubjectName", 0)

$key = New-Object -COM "X509Enrollment.CX509PrivateKey.1"
$key.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
$key.KeySpec = 1
$key.Length = 4096
$key.SecurityDescriptor = "D:PAI(A;;0xd01f01ff;;;SY)(A;;0xd01f01ff;;;BA)(A;;0x80120089;;;NS)"
$key.MachineContext = 1
$key.Create()

$serverauthoid = New-Object -COM "X509Enrollment.CObjectId.1"
$serverauthoid.InitializeFromValue("1.3.6.1.5.5.7.3.1")
$ekuoids = New-Object -COM "X509Enrollment.CObjectIds.1"
$ekuoids.Add($serverauthoid)
$ekuext = New-Object -COM "X509Enrollment.CX509ExtensionEnhancedKeyUsage.1"
$ekuext.InitializeEncode($ekuoids)

$cert = New-Object -COM "X509Enrollment.CX509CertificateRequestCertificate.1"
$cert.InitializeFromPrivateKey(2, $key, "")
$cert.Subject = $name
$cert.Issuer = $cert.Subject
$cert.NotBefore = (Get-Date).AddDays(-1)
$cert.NotAfter = $cert.NotBefore.AddDays($ValidDays)

$SigOID = New-Object -ComObject X509Enrollment.CObjectId
$SigOID.InitializeFromValue(([Security.Cryptography.Oid]$SignatureAlgorithm).Value)

[string[]] $AlternativeName  += $hostnonFQDN
$AlternativeName += $hostFQDN
$IAlternativeNames = New-Object -ComObject X509Enrollment.CAlternativeNames

foreach ($AN in $AlternativeName)
{
$AltName = New-Object -ComObject X509Enrollment.CAlternativeName
$AltName.InitializeFromString(0x3,$AN)
$IAlternativeNames.Add($AltName)
}

$SubjectAlternativeName = New-Object -ComObject X509Enrollment.CX509ExtensionAlternativeNames
$SubjectAlternativeName.InitializeEncode($IAlternativeNames)

[String[]]$KeyUsage = ("DigitalSignature", "KeyEncipherment")
$KeyUsageObj = New-Object -ComObject X509Enrollment.CX509ExtensionKeyUsage
$KeyUsageObj.InitializeEncode([int][Security.Cryptography.X509Certificates.X509KeyUsageFlags]($KeyUsage))
$KeyUsageObj.Critical = $true

$cert.X509Extensions.Add($KeyUsageObj)
$cert.X509Extensions.Add($ekuext)
$cert.SignatureInformation.HashAlgorithm = $SigOID
$CERT.X509Extensions.Add($SubjectAlternativeName)
$cert.Encode()

$enrollment = New-Object -COM "X509Enrollment.CX509Enrollment.1"
$enrollment.InitializeFromRequest($cert)
$certdata = $enrollment.CreateRequest(0)
$enrollment.InstallResponse(2, $certdata, 0, "")

# extract/return the thumbprint from the generated cert
$parsed_cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$parsed_cert.Import([System.Text.Encoding]::UTF8.GetBytes($certdata))

return $parsed_cert.Thumbprint
}

# Setup error handling.
Trap
{
$_
Exit 1
}
$ErrorActionPreference = "Stop"

# Get the ID and security principal of the current user account
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running "as Administrator"
if (-Not $myWindowsPrincipal.IsInRole($adminRole))
{
Write-Output "ERROR: You need elevated Administrator privileges in order to run this script."
Write-Output "       Start Windows PowerShell by using the Run as Administrator option."
Exit 2
}

$EventSource = $MyInvocation.MyCommand.Name
If (-Not $EventSource)
{
$EventSource = "Powershell CLI"
}

If ([System.Diagnostics.EventLog]::Exists('Application') -eq $False -or [System.Diagnostics.EventLog]::SourceExists($EventSource) -eq $False)
{
New-EventLog -LogName Application -Source $EventSource
}

# Detect PowerShell version.
If ($PSVersionTable.PSVersion.Major -lt 3)
{
Write-Log "PowerShell version 3 or higher is required."
Throw "PowerShell version 3 or higher is required."
}

# Find and start the WinRM service.
Write-Verbose "Verifying WinRM service."
If (!(Get-Service "WinRM"))
{
Write-Log "Unable to find the WinRM service."
Throw "Unable to find the WinRM service."
}
ElseIf ((Get-Service "WinRM").Status -ne "Running")
{
Write-Verbose "Setting WinRM service to start automatically on boot."
Set-Service -Name "WinRM" -StartupType Automatic
Write-Log "Set WinRM service to start automatically on boot."
Write-Verbose "Starting WinRM service."
Start-Service -Name "WinRM" -ErrorAction Stop
Write-Log "Started WinRM service."

}

# WinRM should be running; check that we have a PS session config.
If (!(Get-PSSessionConfiguration -Verbose:$false) -or (!(Get-ChildItem WSMan:\localhost\Listener)))
{
If ($SkipNetworkProfileCheck) {
Write-Verbose "Enabling PS Remoting without checking Network profile."
Enable-PSRemoting -SkipNetworkProfileCheck -Force -ErrorAction Stop
Write-Log "Enabled PS Remoting without checking Network profile."
}
Else {
Write-Verbose "Enabling PS Remoting."
Enable-PSRemoting -Force -ErrorAction Stop
Write-Log "Enabled PS Remoting."
}
}
Else
{
Write-Verbose "PS Remoting is already enabled."
}

# Ensure LocalAccountTokenFilterPolicy is set to 1
# https://github.com/ansible/ansible/issues/42978
$token_path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$token_prop_name = "LocalAccountTokenFilterPolicy"
$token_key = Get-Item -Path $token_path
$token_value = $token_key.GetValue($token_prop_name, $null)
if ($token_value -ne 1) {
Write-Verbose "Setting LocalAccountTOkenFilterPolicy to 1"
if ($null -ne $token_value) {
Remove-ItemProperty -Path $token_path -Name $token_prop_name
}
New-ItemProperty -Path $token_path -Name $token_prop_name -Value 1 -PropertyType DWORD > $null
}

# Make sure there is a SSL listener.
$listeners = Get-ChildItem WSMan:\localhost\Listener
If (!($listeners | Where-Object {$_.Keys -like "TRANSPORT=HTTPS"}))
{
# We cannot use New-SelfSignedCertificate on 2012R2 and earlier
$thumbprint = New-LegacySelfSignedCert -SubjectName $SubjectName -ValidDays $CertValidityDays
Write-HostLog "Self-signed SSL certificate generated; thumbprint: $thumbprint"

# Create the hashtables of settings to be used.
$valueset = @{
Hostname = $SubjectName
CertificateThumbprint = $thumbprint
}

$selectorset = @{
Transport = "HTTPS"
Address = "*"
}

Write-Verbose "Enabling SSL listener."
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet $selectorset -ValueSet $valueset
Write-Log "Enabled SSL listener."
}
Else
{
Write-Verbose "SSL listener is already active."

# Force a new SSL cert on Listener if the $ForceNewSSLCert
If ($ForceNewSSLCert)
{

# We cannot use New-SelfSignedCertificate on 2012R2 and earlier
$thumbprint = New-LegacySelfSignedCert -SubjectName $SubjectName -ValidDays $CertValidityDays
Write-HostLog "Self-signed SSL certificate generated; thumbprint: $thumbprint"

$valueset = @{
CertificateThumbprint = $thumbprint
Hostname = $SubjectName
}

# Delete the listener for SSL
$selectorset = @{
Address = "*"
Transport = "HTTPS"
}
Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet $selectorset

# Add new Listener with new SSL cert
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet $selectorset -ValueSet $valueset
}
}

# If EnableCredSSP if set to true
If ($EnableCredSSP)
{
# Check for CredSSP authentication
$credsspAuthSetting = Get-ChildItem WSMan:\localhost\Service\Auth | Where-Object {$_.Name -eq "CredSSP"}
If (($credsspAuthSetting.Value) -eq $false)
{
Write-Verbose "Enabling CredSSP auth support."
Enable-WSManCredSSP -role server -Force
Write-Log "Enabled CredSSP auth support."
}
}

# Configure firewall to allow WinRM HTTPS connections.
$fwtest1 = netsh advfirewall firewall show rule name="Allow WinRM HTTPS"
$fwtest2 = netsh advfirewall firewall show rule name="Allow WinRM HTTPS" profile=any
If ($fwtest1.count -lt 5)
{
Write-Verbose "Adding firewall rule to allow WinRM HTTPS."
netsh advfirewall firewall add rule profile=any name="Allow WinRM HTTPS" dir=in localport=5986 protocol=TCP action=allow
Write-Log "Added firewall rule to allow WinRM HTTPS."
}
ElseIf (($fwtest1.count -ge 5) -and ($fwtest2.count -lt 5))
{
Write-Verbose "Updating firewall rule to allow WinRM HTTPS for any profile."
netsh advfirewall firewall set rule name="Allow WinRM HTTPS" new profile=any
Write-Log "Updated firewall rule to allow WinRM HTTPS for any profile."
}
Else
{
Write-Verbose "Firewall rule already exists to allow WinRM HTTPS."
}

# Test a remoting connection to localhost, which should work.
$httpResult = Invoke-Command -ComputerName "localhost" -ScriptBlock {$env:COMPUTERNAME} -ErrorVariable httpError -ErrorAction SilentlyContinue
$httpsOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

$httpsResult = New-PSSession -UseSSL -ComputerName "localhost" -SessionOption $httpsOptions -ErrorVariable httpsError -ErrorAction SilentlyContinue

If ($httpResult -and $httpsResult)
{
Write-Verbose "HTTP: Enabled | HTTPS: Enabled"
}
ElseIf ($httpsResult -and !$httpResult)
{
Write-Verbose "HTTP: Disabled | HTTPS: Enabled"
}
ElseIf ($httpResult -and !$httpsResult)
{
Write-Verbose "HTTP: Enabled | HTTPS: Disabled"
}
Else
{
Write-Log "Unable to establish an HTTP or HTTPS remoting session."
Throw "Unable to establish an HTTP or HTTPS remoting session."
}
Write-VerboseLog "PS Remoting has been successfully configured for Ansible."