# tools/send-outreach.ps1
#
# Sends one outreach email through Tencent Exmail SMTP as e@ppppp.space.
#
# DESIGN RULES (do not break these):
#  1. NO CREDENTIALS IN THIS FILE, in the command line, or in any log. The mailbox
#     password is read at runtime from a file OUTSIDE the repo:
#         C:\Users\ASUS\AppData\Local\Temp\hypercode\smtp.txt   (first line = password)
#  2. One recipient per run. No lists, no loops, no bcc. These are 5 hand-written
#     emails, not a campaign.
#  3. -DryRun prints exactly what would be sent (headers + body) and sends nothing.
#
# Usage:
#   powershell -File tools/send-outreach.ps1 -To "someone@example.com" `
#       -Subject "..." -BodyFile "docs/sales/outreach-pack.md" -DryRun
#
# Notes:
#  * Port 587 (STARTTLS). .NET's SmtpClient does NOT support implicit-SSL port 465.
#  * Sending from a brand-new domain: prefer the fewest, most personal messages first.

param(
  [Parameter(Mandatory = $true)][string]$To,
  [Parameter(Mandatory = $true)][string]$Subject,
  [Parameter(Mandatory = $true)][string]$BodyFile,
  [string]$From = "e@ppppp.space",
  [string]$FromName = "Everest An",
  [string]$SecretFile = "C:\Users\ASUS\AppData\Local\Temp\hypercode\smtp.txt",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $BodyFile)) { throw "body file not found: $BodyFile" }
$body = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyFile))

if ($DryRun) {
  Write-Output "=== DRY RUN (nothing sent) ==="
  Write-Output ("From   : " + $FromName + " <" + $From + ">")
  Write-Output ("To     : " + $To)
  Write-Output ("Subject: " + $Subject)
  Write-Output ("Body   : " + $body.Length + " chars")
  Write-Output "------------------------------"
  Write-Output $body
  return
}

if (-not (Test-Path -LiteralPath $SecretFile)) {
  throw "password file missing. Create it (first line = the mailbox password) and retry: $SecretFile"
}
$pw = (Get-Content -LiteralPath $SecretFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($pw)) { throw "password file is empty: $SecretFile" }

$msg = New-Object System.Net.Mail.MailMessage
$msg.From = New-Object System.Net.Mail.MailAddress($From, $FromName)
$msg.To.Add($To)
$msg.Subject = $Subject
$msg.Body = $body
$msg.IsBodyHtml = $false
$msg.BodyEncoding = [System.Text.Encoding]::UTF8
$msg.SubjectEncoding = [System.Text.Encoding]::UTF8

$smtp = New-Object System.Net.Mail.SmtpClient("smtp.exmail.qq.com", 587)
$smtp.EnableSsl = $true
$smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
$smtp.Credentials = New-Object System.Net.NetworkCredential($From, $pw)
$smtp.Timeout = 60000

Write-Output ("sending to " + $To + " via smtp.exmail.qq.com:587 (STARTTLS) as " + $From + " ...")
$smtp.Send($msg)
$smtp.Dispose(); $msg.Dispose()
Write-Output "sent OK"
