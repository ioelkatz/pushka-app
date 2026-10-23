<#
.SYNOPSIS
  Carga un secreto en Firebase Secret Manager sin que su valor pase por la
  linea de comando ni quede en disco.

.DESCRIPTION
  El valor se toma del portapapeles. Nunca se escribe como argumento, por dos
  motivos que ya nos mordieron:

    1. PowerShell guarda en texto plano todo lo que se tipea en la consola
       -- ver (Get-PSReadLineOption).HistorySavePath. Una clave pegada en la
       linea de comando queda ahi indefinidamente.

    2. Read-Host NO acepta Ctrl+V: inserta un caracter de control literal.
       El 2026-10-23 eso guardo un caracter basura como STRIPE_SECRET_KEY,
       se redesplegaron 26 funciones con el, y los pagos de produccion
       quedaron caidos hasta que se detecto. Por eso este script VALIDA
       antes de escribir nada, y aborta sin tocar Firebase si algo no da.

  El archivo temporal se escribe sin salto de linea final y sin marca de
  codificacion (BOM): cualquiera de las dos corrompe el secreto. Con un
  salto de linea al final, el SDK de Stripe tira ERR_INVALID_CHAR al armar
  el header Authorization, y el sintoma que se ve es
  "StripeConnectionError: An error occurred with our connection to Stripe",
  que no apunta a nada util.

.EXAMPLE
  .\scripts\set-secret.ps1 -Nombre STRIPE_SECRET_KEY -Proyecto pushka-app-ioel -Prefijo sk_live_

.EXAMPLE
  .\scripts\set-secret.ps1 -Nombre BREVO_API_KEY -Proyecto pushka-app-ioel
#>
param(
  [Parameter(Mandatory = $true)] [string] $Nombre,
  [Parameter(Mandatory = $true)] [string] $Proyecto,
  [string] $Prefijo = "",
  [int] $LargoMinimo = 20
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  Secreto : $Nombre" -ForegroundColor Cyan
Write-Host "  Proyecto: $Proyecto" -ForegroundColor Cyan
if ($Prefijo) { Write-Host "  Esperado: empieza con '$Prefijo'" -ForegroundColor Cyan }
Write-Host ""
Write-Host "  PASO 1: copia el valor al portapapeles." -ForegroundColor Yellow
Write-Host "  PASO 2: volve aca y presiona Enter." -ForegroundColor Yellow
Write-Host ""
Write-Host "  (copia el valor AHORA, no antes: si copiaste este comando," -ForegroundColor DarkGray
Write-Host "   el portapapeles ya no tiene el secreto)" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Enter cuando lo tengas copiado" | Out-Null

$valor = Get-Clipboard -Raw
if ($null -eq $valor -or $valor -eq "") {
  Write-Host "  ABORTA: el portapapeles esta vacio. No se toco nada." -ForegroundColor Red
  exit 1
}
$valor = $valor.Trim()

$asomo = $valor.Substring(0, [Math]::Min(10, $valor.Length))

if ($Prefijo -and -not $valor.StartsWith($Prefijo)) {
  Write-Host "  ABORTA: esperaba '$Prefijo' y empieza con '$asomo'." -ForegroundColor Red
  Write-Host "  No se toco nada." -ForegroundColor Red
  exit 1
}
if ($valor.Length -lt $LargoMinimo) {
  Write-Host "  ABORTA: largo $($valor.Length), minimo esperado $LargoMinimo." -ForegroundColor Red
  Write-Host "  No se toco nada." -ForegroundColor Red
  exit 1
}
if ($valor -match '\s') {
  Write-Host "  ABORTA: el valor trae espacios o saltos de linea adentro." -ForegroundColor Red
  Write-Host "  No se toco nada." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "  OK -- largo $($valor.Length), sin espacios, prefijo correcto." -ForegroundColor Green
Write-Host ""

$ruta = Join-Path $env:TEMP ("secreto-" + [guid]::NewGuid().ToString() + ".txt")
[System.IO.File]::WriteAllText($ruta, $valor, (New-Object System.Text.UTF8Encoding $false))

try {
  firebase functions:secrets:set $Nombre --project $Proyecto --data-file $ruta
} finally {
  Remove-Item $ruta -Force -ErrorAction SilentlyContinue
  Remove-Variable valor -ErrorAction SilentlyContinue
  Write-Host ""
  Write-Host "  Archivo temporal borrado." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Verifica que produccion siga en pie antes de revocar nada viejo:" -ForegroundColor Yellow
Write-Host "    curl https://us-central1-pushka-app-ioel.cloudfunctions.net/health" -ForegroundColor Yellow
Write-Host "  Tiene que devolver stripe:ok y HTTP 200." -ForegroundColor Yellow
Write-Host ""
