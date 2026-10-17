if (-not (Test-Path "E:\")) { Write-Host "E: drive not found" -ForegroundColor Red; exit }

Get-Process java -ErrorAction SilentlyContinue | Stop-Process -Force

New-Item -ItemType Directory -Force "E:\gradle_home","E:\pub_cache","E:\temp" | Out-Null

$env:GRADLE_USER_HOME = "E:\gradle_home"
$env:PUB_CACHE = "E:\pub_cache"
$env:TEMP = "E:\temp"
$env:TMP = "E:\temp"
[Environment]::SetEnvironmentVariable("GRADLE_USER_HOME","E:\gradle_home","User")
[Environment]::SetEnvironmentVariable("PUB_CACHE","E:\pub_cache","User")

Remove-Item "$env:USERPROFILE\.gradle" -Recurse -Force -ErrorAction SilentlyContinue

flutter pub get

for ($i=1; $i -le 3; $i++) {
  Write-Host "Attempt $i of 3" -ForegroundColor Yellow
  flutter build apk --debug
  if (Test-Path "build\app\outputs\flutter-apk\app-debug.apk") {
    Write-Host "SUCCESS - APK is ready" -ForegroundColor Green
    explorer "build\app\outputs\flutter-apk"
    break
  }
}