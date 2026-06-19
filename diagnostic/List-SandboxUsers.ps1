<#
.SYNOPSIS
    Lista los usuarios del tenant actual que TIENEN licencia E5 y buzón, para
    identificar cuál usar como MS_GRAPH_USER_EMAIL del workflow.

.DESCRIPTION
    El workflow hace POST /users/{email}/calendar/events. Para que funcione,
    el usuario debe:
      - Existir en Entra ID
      - Tener licencia E5 asignada (que incluye Exchange Online = buzón)
      - Tener el buzón accesible vía Graph

    Este script lista todos los usuarios y marca cuáles cumplen, para que elijas
    uno (típicamente el admin del sandbox) y lo pongas en el secret.

    REQUISITO: sesión conectada al tenant DEL SANDBOX (45sl3t.onmicrosoft.com),
    no al de tu empresa. Si entraste con fabian.gonzalez@psicometrica.co, estás
    en el tenant equivocado. Reconecta con:
      Connect-MgGraph -TenantId "45sl3t.onmicrosoft.com" -Scopes "User.Read.All","MailboxSettings.Read"

.EXAMPLE
    pwsh .\diagnostic\List-SandboxUsers.ps1
#>
[CmdletBinding()]
param(
    # Tenant del sandbox E5. Si se pasa y NO hay sesion activa, el script se
    # conecta el mismo (en la misma sesion de PowerShell) antes de seguir.
    [string]$TenantId = "45sl3t.onmicrosoft.com"
)
$ErrorActionPreference = 'Continue'

function Write-Section($t){ Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-Bad($m){ Write-Host "  [FAIL]  $m" -ForegroundColor Red }
function Write-Info($m){ Write-Host "  [i]     $m" -ForegroundColor DarkGray }

Write-Section "0. Comprobar tenant actual"
$ctx = Get-MgContext
if (-not $ctx -or [string]::IsNullOrEmpty($ctx.Account)) {
    Write-Warn2 "No hay sesion activa en este proceso. Conectando a '$TenantId'..."
    # Asegurar que el modulo esta cargado en ESTE proceso
    if (-not (Get-Module Microsoft.Graph.Authentication)) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
    }
    Connect-MgGraph -TenantId $TenantId -Scopes "User.Read.All","MailboxSettings.Read","Organization.Read.All" -ErrorAction Stop | Out-Null
    $ctx = Get-MgContext
    if (-not $ctx) { Write-Bad "No se pudo conectar."; exit 1 }
    Write-Ok "Conexion establecida."
}
Write-Info "Conectado como: $($ctx.Account)"
Write-Info "Tenant ID: $($ctx.TenantId)"

# Verificar que estamos en el tenant del sandbox
try {
    $domains = Get-MgDomain -ErrorAction Stop
    $hasSandboxDomain = $domains.Id -contains '45sl3t.onmicrosoft.com'
    if (-not $hasSandboxDomain) {
        Write-Bad "NO estas en el tenant del sandbox E5."
        Write-Bad "Dominios del tenant actual: $($domains.Id -join ', ')"
        Write-Bad "Reconecta al tenant correcto:"
        Write-Bad '  Disconnect-MgGraph'
        Write-Bad '  Connect-MgGraph -TenantId "45sl3t.onmicrosoft.com"'
        exit 2
    }
    Write-Ok "Confirmado: estas en el tenant del sandbox (45sl3t.onmicrosoft.com)."
} catch {
    Write-Warn2 "No se pudieron verificar dominos: $($_.Exception.Message)"
}

Write-Section "1. Usuarios con licencia E5 y estado del buzón"
try {
    $users = Get-MgUser -All -Property id,userPrincipalName,displayName,accountEnabled,assignedLicenses -ErrorAction Stop
    Write-Info "Total usuarios en el tenant: $($users.Count)"
    Write-Host ""
    Write-Host ("{0,-45} {1,-12} {2,-8} {3,-10} {4}" -f "UPN","Licencias","Activado","Buzon","Nombre") -ForegroundColor White
    Write-Host ("{0,-45} {1,-12} {2,-8} {3,-10} {4}" -f ("-"*45),"----------","--------","----------","------") -ForegroundColor DarkGray

    $candidates = @()
    foreach ($u in $users) {
        $lic = if ($u.AssignedLicenses.Count -gt 0) { "E5/SI" } else { "(ninguna)" }
        $enabled = if ($u.AccountEnabled) { "SI" } else { "NO" }
        $mb = "?"
        try {
            $null = Get-MgUserMailboxSetting -UserId $u.UserPrincipalName -ErrorAction Stop
            $mb = "OK"
            if ($u.AssignedLicenses.Count -gt 0 -and $u.AccountEnabled) {
                $candidates += $u.UserPrincipalName
            }
        } catch {
            $mb = "SIN BUZON"
        }
        $color = if ($mb -eq "OK" -and $u.AssignedLicenses.Count -gt 0 -and $u.AccountEnabled) { "Green" } else { "Gray" }
        Write-Host ("{0,-45} {1,-12} {2,-8} {3,-10} {4}" -f $u.UserPrincipalName,$lic,$enabled,$mb,$u.DisplayName) -ForegroundColor $color
    }
} catch {
    Write-Bad "No se pudo listar usuarios: $($_.Exception.Message)"
    exit 3
}

Write-Section "2. Candidatos validos para MS_GRAPH_USER_EMAIL"
if ($candidates.Count -eq 0) {
    Write-Bad "Ningun usuario cumple (licencia + activado + buzón)."
    Write-Bad "Posible causa del 404: todos los buzones estan desactivados (suscripcion en gracia/caducada)."
} else {
    Write-Ok "Candidatos validos (verde arriba):"
    foreach ($c in $candidates) { Write-Host "    $c" -ForegroundColor Green }
    Write-Host ""
    Write-Warn2 "Recomendado: el admin del sandbox suele ser falegoro@45sl3t.onmicrosoft.com"
    Write-Host "Pon ese UPN en el secret MS_GRAPH_USER_EMAIL de GitHub."
}
