<#
.SYNOPSIS
    Determina si el tenant actual es un sandbox del Microsoft 365 Developer Program
    o un tenant empresarial normal. Ayuda a saber si estas diagnosticando en el
    tenant correcto para el workflow E5.
.DESCRIPTION
    Un sandbox del Developer Program tiene señales muy reconocibles:
      - Dominios *.onmicrosoft.com especificos del dev program
      - Licencias con SKU "DEVELOPERPACK" (Microsoft 365 E5 developer)
      - Pocos usuarios (1-25), con un admin generado
      - Etiqueta "Microsoft 365 Developer Program" en algunos metadatos
.EXAMPLE
    pwsh .\diagnostic\Check-TenantType.ps1
    (Requiere sesion de Microsoft Graph activa. Si no la hay, ejecuta antes
     Connect-MgGraph -Scopes "Organization.Read.All","User.Read.All")
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'

function Write-Section($t){ Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-Bad($m){ Write-Host "  [FAIL]  $m" -ForegroundColor Red }
function Write-Info($m){ Write-Host "  [i]     $m" -ForegroundColor DarkGray }

Write-Section "0. Sesion de Graph"
$ctx = Get-MgContext
if (-not $ctx -or [string]::IsNullOrEmpty($ctx.Account)) {
    Write-Bad "No hay sesion activa. Ejecuta primero:"
    Write-Bad '  Connect-MgGraph -Scopes "Organization.Read.All","User.Read.All","User.ReadBasic.All"'
    exit 1
}
Write-Ok "Conectado como: $($ctx.Account)"
Write-Ok "Tenant ID: $($ctx.TenantId)"

Write-Section "1. Dominios verificados del tenant"
try {
    $domains = Get-MgDomain -All -ErrorAction Stop
    $devScore = 0
    foreach ($d in $domains) {
        $flag = if ($d.IsDefault) { " (default)" } else { "" }
        Write-Info "  $($d.Id)$flag"
        # Pistas de sandbox del dev program
        if ($d.Id -match '\.onmicrosoft\.com$')      { $devScore++ ; Write-Warn2 "    ^ dominio *.onmicrosoft.com (comun en sandboxes)" }
        if ($d.Id -match '\.mail\.onmicrosoft\.com$')  { $devScore++ }
        if ($d.Id -match 'M365x|E5|dev|sandbox' -and $d.Id -match 'onmicrosoft') { $devScore++ }
    }
} catch {
    Write-Bad "No se pudieron leer dominios: $($_.Exception.Message)"
    Write-Bad 'Falta el permiso? Intenta: Connect-MgGraph -Scopes "Domain.Read.All"'
}

Write-Section "2. Informacion de la organizacion (razon social / inquilino)"
try {
    $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
    Write-Info "  DisplayName       : $($org.DisplayName)"
    Write-Info "  Name              : $($org.Name)"
    Write-Info "  City/Country      : $($org.City) / $($org.Country)"
    Write-Info "  DirSyncEnabled    : $($org.DirSyncEnabled)"
    # Los sandboxes suelen tener el nombre en ingles tipo "Microsoft 365 Developer Program"
    if ($org.DisplayName -match 'Developer|Dev Program|M365x|E5') {
        $devScore += 3
        Write-Warn2 "  ^ DisplayName sugiere sandbox del dev program"
    }
} catch {
    Write-Bad "No se pudo leer la organizacion: $($_.Exception.Message)"
}

Write-Section "3. Licencias (SKUs) del tenant"
$devLicenseFound = $false
try {
    $skus = Get-MgSubscribedSku -ErrorAction Stop
    if (-not $skus) { Write-Warn2 "El tenant NO tiene NINGUNA licencia comprada. Sospechoso de tenant sin E5." }
    foreach ($s in $skus) {
        $consumed = $s.PrepaidUnits.Enabled
        $used = $s.ConsumedUnits
        Write-Info "  $($s.SkuPartNumber)  (disponibles=$consumed, en uso=$used)"
        # El SKU del developer program es "DEVELOPERPACK_E5" o similar
        if ($s.SkuPartNumber -match 'DEVELOPERPACK') {
            $devLicenseFound = $true
            $devScore += 5
            Write-Warn2 "    ^ LICENCIA DEL DEVELOPER PROGRAM detectada: $($s.SkuPartNumber)"
        }
        if ($s.SkuPartNumber -match 'E5|ENTERPRISEPREMIUM|SPE_F1') {
            $devScore += 1
        }
    }
} catch {
    Write-Bad "No se pudieron leer SKUs: $($_.Exception.Message)"
}

Write-Section "4. Numero de usuarios (los sandboxes tienen pocos)"
try {
    $users = Get-MgUser -All -ErrorAction Stop
    Write-Info "  Total de usuarios en el tenant: $($users.Count)"
    if ($users.Count -le 25) {
        $devScore += 2
        Write-Warn2 "  ^ Pocos usuarios (<=25): tipico de un sandbox/personal, raro en empresa"
    } else {
        Write-Info "  ^ Tenant con muchos usuarios: mas probable de empresa"
    }
} catch {
    Write-Warn2 "No se pudo contar usuarios: $($_.Exception.Message)"
}

Write-Section "5. Veredicto"
Write-Host "  Puntuacion de 'parece sandbox del Developer Program': $devScore" -ForegroundColor White
if ($devLicenseFound) {
    Write-Ok "CONFIRMADO: este tenant tiene licencia DEVELOPERPACK. ES el sandbox E5."
} elseif ($devScore -ge 4) {
    Write-Warn2 "Probablemente SI sea el sandbox del Developer Program (sin licencia explicita detectada)."
} else {
    Write-Bad "Probablemente NO es el sandbox E5. Es un tenant de empresa u otro."
    Write-Bad "Necesitas cambiar al tenant correcto del Developer Program."
}
