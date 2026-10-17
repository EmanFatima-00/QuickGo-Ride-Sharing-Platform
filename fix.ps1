$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding $false

# 1) Android permissions
$mf = Join-Path $root "android\app\src\main\AndroidManifest.xml"
$t = [System.IO.File]::ReadAllText($mf)
if ($t -notmatch "ACCESS_FINE_LOCATION") {
  $nl = "`r`n    "
  $perm = '<uses-permission android:name="android.permission.INTERNET"/>' + $nl
  $perm += '<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>' + $nl
  $perm += '<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>' + $nl
  $perm += '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>' + $nl
  $t = $t.Replace('<application', $perm + '<application')
  [System.IO.File]::WriteAllText($mf, $t, $utf8)
}

# 2) Core library desugaring (needed by notifications package)
$gk = Join-Path $root "android\app\build.gradle.kts"
$gg = Join-Path $root "android\app\build.gradle"
if (Test-Path $gk) {
  $g = [System.IO.File]::ReadAllText($gk)
  if ($g -notmatch "isCoreLibraryDesugaringEnabled") {
    $re = [regex]"compileOptions\s*\{"
    $g = $re.Replace($g, "compileOptions {`r`n        isCoreLibraryDesugaringEnabled = true", 1)
  }
  if ($g -notmatch "desugar_jdk_libs") {
    $g += "`r`ndependencies {`r`n    " + 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")' + "`r`n}`r`n"
  }
  [System.IO.File]::WriteAllText($gk, $g, $utf8)
} elseif (Test-Path $gg) {
  $g = [System.IO.File]::ReadAllText($gg)
  if ($g -notmatch "coreLibraryDesugaringEnabled") {
    $re = [regex]"compileOptions\s*\{"
    $g = $re.Replace($g, "compileOptions {`r`n        coreLibraryDesugaringEnabled true", 1)
  }
  if ($g -notmatch "desugar_jdk_libs") {
    $g += "`r`ndependencies {`r`n    " + "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'" + "`r`n}`r`n"
  }
  [System.IO.File]::WriteAllText($gg, $g, $utf8)
}

# 3) Upgrade the packages that fail to build
flutter pub add "geolocator:>=14.0.0 <15.0.0" "flutter_local_notifications:>=19.0.0 <20.0.0"
flutter clean
flutter pub get

# 4) Build the APK
cmd /c "flutter build apk --debug > build_log.txt 2>&1"

if (Test-Path "build\app\outputs\flutter-apk\app-debug.apk") {
  Write-Host "SUCCESS - APK is ready" -ForegroundColor Green
  explorer "build\app\outputs\flutter-apk"
} else {
  Write-Host "FAILED - reason below" -ForegroundColor Red
  Get-Content build_log.txt | Select-String -Pattern "evaluating project|went wrong|error:" -Context 0,4
}