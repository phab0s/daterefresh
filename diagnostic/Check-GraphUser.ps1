<#
.SYNOPSIS
    Diagnostica la causa raiz del error HTTP 404 "ErrorInvalidUser" obtenido al
    crear un evento en el calendario de Outlook via Microsoft Graph desde el
    workflow auto-activity.yml.

.DESCRIPTION
    El workflow falla en el paso 10 (POST /users/{email}/calendar/events) con:
        HTTP 404  {"code":"ErrorInvalidUser","message":"The requested user '...' is invalid."}

    Este 404 NO es un problema de permisos Mail.Send (eso seria 403). Indica que
    Graph no puede resolver el identificador de usuario de la URL como un buzon
    valido/accesible. Este script aisla cual de estas es la causa:

      A) El identificador (email/UPN) es incorrecto o esta vacio
      B) El usuario existe en Entra ID pero NO tiene buzon de Exchange (sin licencia E5)
      C) El UPN cambio, o el mailbox esta inactivo/hard-deleted en Exchange
      D) El Service Principal de la app no tiene permisos Calendars.ReadWrite
         (en cuyo caso veriamos 403, pero lo verificamos por descarte)

.PARAMETER UserEmail
    El valor EXACTO que tienes configurado en el secret
    MS_GRAPH_USER_EMAIL de GitHub (debe ser el UPN del usuario E5).

.PARAMETER AppClientId
    (Opcional) El clientId (Application ID) de la App Registration que usa el
    workflow (secret AZURE_CLIENT_ID). Sirve para listar los permisos de Graph
    que tiene concedidos. Si no se pasa, se omite esa verificacion.

.EXAMPLE
    .\Check-GraphUser.ps1 -UserEmail "usuario@tudominio.onmicrosoft.com"
    .\Check-GraphUser.ps1 -UserEmail "usuario@tudominio.onmicrosoft.com" -AppClientId "11111111-2222-3333-4444-555555555555"

.NOTES
    Requiere el modulo Microsoft.Graph.Authentication (se instala automaticamente
    si falta). Te pedira login interactivo con una cuenta con permisos de admin
    del tenant (lectura de usuarios, buzones y service principals).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UserEmail,

    [Parameter(Mandatory = $false)]
    [string]$AppClientId,

    # Tenant del sandbox E5. Si NO hay sesion activa al ejecutar el script, se
    # conecta solo a este tenant (mismo proceso) antes de seguir.
    [Parameter(Mandatory = $false)]
    [string]$TenantId = "45sl3t.onmicrosoft.com"
)

$ErrorActionPreference = 'Continue'

function Write-Section($title) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Write-Ok($msg)   { Write-Host "  [OK]    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "  [FAIL]  $msg" -ForegroundColor Red }
function Write-Info($msg) { Write-Host "  [INFO]  $msg" -ForegroundColor DarkGray }

# ----------------------------------------------------------------------------
# 0. Pre-requisitos: instalar el meta-modulo Microsoft.Graph.
#    IMPORTANTE: los cmdlets Get-MgUser, Get-MgUserCalendar, Get-MgSubscribedSku
#    y Get-MgServicePrincipal NO viven en submodulos sueltos. El unico que los
#    expone todos correctamente es el meta-modulo "Microsoft.Graph" (que agrupa
#    Users, Users.Calendar, Applications, Identity.DirectoryManagement, etc.).
#    Instalar submodulos individuales como "Microsoft.Graph.Users.Calendar"
#    NO funciona: ese modulo no se publica por separado en PSGallery.
# ----------------------------------------------------------------------------
Write-Section "0. Pre-requisitos"
# Lista de cmdlets que el script usa. Se verifican tras importar.
$requiredCmdlets = @(
    'Get-MgUser',
    'Get-MgUserCalendar',
    'Get-MgUserMailboxSetting',
    'Get-MgSubscribedSku',
    'Get-MgServicePrincipal',
    'Get-MgContext'
)
$meta = Get-Module -ListAvailable Microsoft.Graph | Sort-Object Version -Descending | Select-Object -First 1
if (-not $meta) {
    Write-Warn2 "Microsoft.Graph no esta instalado. Instalando el meta-modulo (Scope CurrentUser)..."
    Write-Warn2 "Esto trae TODOS los submodulos (pesa ~varios cientos de MB). Puede tardar un par de minutos."
    Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    $meta = Get-Module -ListAvailable Microsoft.Graph | Sort-Object Version -Descending | Select-Object -First 1
} else {
    Write-Ok "Microsoft.Graph presente (v$($meta.Version))"
}
Import-Module Microsoft.Graph -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# 1. Login interactivo con los scopes necesarios para el diagnostico
#    Usamos scopes delegados (User.Read, User.ReadBasic.All, Calendars.Read,
#    MailboxSettings.Read, Directory.Read.All) para poder inspeccionar todo.
# ----------------------------------------------------------------------------
Write-Section "1. Iniciando sesion en Microsoft Graph (interactivo)"
try {
    # Si ya hay sesion activa en este proceso, reutilizarla; si no, conectar al tenant.
    $existingCtx = Get-MgContext
    if (-not $existingCtx -or [string]::IsNullOrEmpty($existingCtx.Account)) {
        Write-Warn2 "No hay sesion activa. Conectando al tenant '$TenantId'..."
        Connect-MgGraph -TenantId $TenantId -Scopes "User.Read.All","User.ReadBasic.All","Calendars.Read","Calendars.ReadWrite","MailboxSettings.Read","Directory.Read.All" -ErrorAction Stop | Out-Null
    }
    $context = Get-MgContext
    Write-Ok "Conectado como: $($context.Account)"
    Write-Ok "Tenant: $($context.TenantId)"
    Write-Info "Hostname Graph: $($context.GraphEndpoint)"
    # Aviso de tipo de cuenta: confirma que el tenant es el esperado (E5 dev).
    Write-Info "Si el tenant arriba NO es el de tu suscripcion E5, cierra sesion"
    Write-Info "con Disconnect-MgGraph y vuelve a loguearte en el tenant correcto."

    # Defensa en profundidad: verificar que los cmdlets clave existen tras importar.
    # Si no existen, abortar con mensaje claro en vez de producir un falso negativo.
    $missing = @()
    foreach ($cmd in $requiredCmdlets) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
    }
    if ($missing.Count -gt 0) {
        Write-Bad "Faltan cmdlets de Microsoft.Graph aunque el meta-modulo esta instalado:"
        $missing | ForEach-Object { Write-Bad "  - $_" }
        Write-Bad "Solucionalo con:  Install-Module Microsoft.Graph -Scope CurrentUser -Force"
        exit 1
    } else {
        Write-Ok "Cmdlets necesarios disponibles (Get-MgUser, Get-MgUserCalendar, ...)."
    }
} catch {
    Write-Bad "No se pudo iniciar sesion: $($_.Exception.Message)"
    exit 1
}

# ----------------------------------------------------------------------------
# 2. Validacion basica del identificador recibido
# ----------------------------------------------------------------------------
Write-Section "2. Validacion del identificador recibido ($UserEmail)"
if ([string]::IsNullOrWhiteSpace($UserEmail)) {
    Write-Bad "El identificador esta VACIO. Esto producira exactamente el 404 ErrorInvalidUser (URL /users//calendar/events)."
    Write-Bad "=> CAUSA RAIZ PROBABLE: el secret MS_GRAPH_USER_EMAIL esta vacio en GitHub."
    exit 2
}
if ($UserEmail -match '[\r\n\t]') {
    Write-Bad "El identificador contiene caracteres de control (CR/LF/TAB). Esto corrompe la URL de Graph."
    Write-Bad "Valor sanitizado: '$($UserEmail -replace '[\r\n\t]','<CTRL>')'"
    Write-Bad "=> CAUSA RAIZ PROBABLE: el secret se copio con un salto de linea final."
}
if ($UserEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Write-Warn2 "El identificador NO tiene formato de email (UPN). Si guardaste el objectId GUID en vez del UPN, Graph puede fallar segun el endpoint."
}
if ($UserEmail -notmatch '[\r\n\t]' -and $UserEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Write-Ok "Formato de email/UPN valido y sin caracteres de control."
}

# ----------------------------------------------------------------------------
# 3. ¿Existe el usuario en Entra ID (Azure AD)?
#    GET /users/{email}  -> 200 = existe | 404 = no existe
# ----------------------------------------------------------------------------
Write-Section "3. ¿Existe el usuario en Entra ID?"
try {
    $user = Get-MgUser -UserId $UserEmail -Property id,displayName,userPrincipalName,mail,accountEnabled,assignedLicenses,createdDateTime -ErrorAction Stop
    Write-Ok "Usuario encontrado en Entra ID."
    Write-Info "  objectId (id)            : $($user.id)"
    Write-Info "  displayName              : $($user.displayName)"
    Write-Info "  userPrincipalName (UPN)  : $($user.userPrincipalName)"
    Write-Info "  mail                     : $($user.mail)"
    Write-Info "  accountEnabled           : $($user.accountEnabled)"
    if ($user.userPrincipalName -ne $UserEmail) {
        Write-Warn2 "ATENCION: el UPN real ($($user.userPrincipalName)) difiere del valor que pasaste ($UserEmail)."
        Write-Warn2 "Usar el UPN en el secret suele ser lo mas fiable para /users/{id}/calendar."
    }
} catch {
    Write-Bad "Get-MgUser fallo: $($_.Exception.Message)"
    Write-Bad "=> El usuario NO existe en Entra ID con ese identificador. Revisa el secret MS_GRAPH_USER_EMAIL."
    exit 3
}

if (-not $user.accountEnabled) {
    Write-Bad "La cuenta esta DESHABILITADA. Aunque exista, algunas cargas de Exchange pueden rechazarla."
}

# ----------------------------------------------------------------------------
# 4. ¿Tiene buzon de Exchange? (¿tiene licencia E5?)
#    Un usuario sin licencia E5/E3 que incluya Exchange Online NO tiene buzon,
#    por lo que /calendar devuelve 404 ErrorInvalidUser aunque /users devuelva 200.
# ----------------------------------------------------------------------------
Write-Section "4. Licencias asignadas (¿tiene plan de Exchange Online?)"
if ($user.assignedLicenses.Count -eq 0) {
    Write-Bad "El usuario NO tiene NINGUNA licencia asignada. Sin licencia de Exchange Online = sin buzon = /calendar devuelve 404."
    Write-Bad "=> CAUSA RAIZ PROBABLE: se perdio la licencia E5 (renovacion de suscripcion del programa Microsoft 365 Developer)."
} else {
    Write-Ok "El usuario tiene $($user.assignedLicenses.Count) plan(es) de licencia asignado(s)."
    # Intentar resolver el SKU a nombre legible
    try {
        $skus = Get-MgSubscribedSku -ErrorAction Stop
        foreach ($al in $user.assignedLicenses) {
            $sku = $skus | Where-Object { $_.SkuId -eq $al.SkuId }
            $name = if ($sku) { $sku.SkuPartNumber } else { "SkuId=$($al.SkuId)" }
            Write-Info "  Licencia: $name"
            if ($sku.SkuPartNumber -match 'DEVELOPERPACK|ENTERPRISEPACK|SPE_') {
                Write-Ok "  -> Incluye Exchange Online (buzon disponible)."
            }
        }
    } catch {
        Write-Warn2 "No se pudo resolver el nombre del SKU: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# 5. ¿Es accesible el calendario via Graph? (reproduce el endpoint del workflow)
#    GET /users/{email}/calendar  -> 200 = accesible | 404 = sin buzon
# ----------------------------------------------------------------------------
Write-Section "5. Reproduccion del endpoint del workflow: GET /users/{email}/calendar"
try {
    $cal = Get-MgUserCalendar -UserId $UserEmail -ErrorAction Stop
    Write-Ok "Calendario accesible. name='$($cal.name)' owner='$($cal.owner.address)'"
} catch {
    $msg = $_.Exception.Message
    Write-Bad "Get-MgUserCalendar fallo: $msg"
    if ($msg -match '404|NotFound|ErrorItemNotFound|ErrorInvalidUser|ResourceNotFound') {
        Write-Bad "=> CAUSA RAIZ CONFIRMADA: el usuario existe pero Graph no puede resolver su calendario."
        Write-Bad "   Casi siempre significa: buzon de Exchange ausente, inactivo o sin licencia."
        Write-Bad "   Acciones recomendadas:"
        Write-Bad "     a) Entra ID > Usuarios > {usuario} > Licencias: confirma que el plan E5 (Developer) este activo."
        Write-Bad "     b) Si la suscripcion del developer program expiro, renuevala y reasigna la licencia."
        Write-Bad "     c) Comprueba en el portal de Microsoft 365 que el buzon aparezca como activo."
    }
}

# ----------------------------------------------------------------------------
# 6. MailboxSettings: confirma presencia de buzon y zona horaria
# ----------------------------------------------------------------------------
Write-Section "6. MailboxSettings (presencia/estado del buzon)"
try {
    $mb = Get-MgUserMailboxSetting -UserId $UserEmail -ErrorAction Stop
    Write-Ok "MailboxSettings accesibles. timeZone='$($mb.TimeZone)' purpose='$($mb.UserPurpose)'"
    if ($mb.UserPurpose -eq 'Shared' -or $mb.UserPurpose -eq 'Equipment') {
        Write-Warn2 "El proposito del buzon es '$($mb.UserPurpose)'. /calendar/events puede comportarse distinto."
    }
} catch {
    Write-Bad "No se pudieron leer MailboxSettings: $($_.Exception.Message)"
    Write-Bad "=> Confirma ausencia de buzon para este usuario."
}

# ----------------------------------------------------------------------------
# 7. (Opcional) Permisos del Service Principal de la App
# ----------------------------------------------------------------------------
if ($AppClientId) {
    Write-Section "7. Permisos de Graph concedidos a la App (Service Principal)"
    try {
        $sp = Get-MgServicePrincipal -Filter "appId eq '$AppClientId'" -ErrorAction Stop | Select-Object -First 1
        if ($sp) {
            Write-Ok "Service Principal encontrado: $($sp.DisplayName)"
            $oauth2 = $sp.Oauth2PermissionScopes  # delegados
            $appRoles = $sp.AppRoles               # de aplicacion
            Write-Info "Permisos delegados (Oauth2PermissionScopes):"
            $oauth2 | ForEach-Object { Write-Info "  - $($_.Value)" }
            Write-Info "Permisos de aplicacion (AppRoles):"
            $appRoles | ForEach-Object { Write-Info "  - $($_.Value)" }

            # Verificar concedidos a nivel de tenant para el SP
            $spAssign = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue
            $appAssign = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue
            Write-Info "Scope concedido (delegado) en el tenant: $(($spAssign.Scope) -join ', ')"
            # Resolver el nombre (Value) de cada AppRole concedido. El AppRoleAssignment
            # expone .AppRoleId; lo cruzamos con la coleccion $appRoles (que tiene .Id y .Value).
            $appGrantNames = foreach ($assign in $appAssign) {
                $matched = $appRoles | Where-Object { $_.Id -eq $assign.AppRoleId }
                if ($matched) { $matched.Value } else { "<AppRoleId=$($assign.AppRoleId)>" }
            }
            Write-Info "AppRoles concedidos en el tenant: $($appGrantNames -join ', ')"

            $need = @('Calendars.ReadWrite','Mail.Send','Mail.ReadWrite','User.Read.All')
            foreach ($n in $need) {
                $hasDelegated = $oauth2 | Where-Object { $_.Value -eq $n }
                $hasApp       = $appRoles | Where-Object { $_.Value -eq $n }
                if ($hasDelegated -or $hasApp) { Write-Ok "Permiso '$n' presente en la definicion de la app." }
                else { Write-Warn2 "Permiso '$n' NO esta en la definicion de la app (revisar si hace falta)." }
            }
        } else {
            Write-Warn2 "No se encontro Service Principal con appId='$AppClientId'."
        }
    } catch {
        Write-Warn2 "No se pudo inspeccionar el Service Principal: $($_.Exception.Message)"
    }
} else {
    Write-Section "7. (Omitido) Permisos de la App"
    Write-Info "Pasa -AppClientId <AZURE_CLIENT_ID> para inspeccionar los permisos del Service Principal."
}

# ----------------------------------------------------------------------------
# 8. Resumen ejecutivo
# ----------------------------------------------------------------------------
Write-Section "8. Resumen ejecutivo"
Write-Host "  Revisa arriba las lineas [FAIL] y [WARN]; indican la causa raiz." -ForegroundColor White
Write-Host "  Recordatorio: el error del workflow fue 404 ErrorInvalidUser, NO 403." -ForegroundColor White
Write-Host "  Eso descarta un problema de permisos Mail.Send y apunta a:" -ForegroundColor White
Write-Host "    - Secret vacio/mal formado, o" -ForegroundColor White
Write-Host "    - Usuario sin buzon (licencia E5 perdida), o" -ForegroundColor White
Write-Host "    - UPN cambiado." -ForegroundColor White
Write-Host ""
Disconnect-MgGraph | Out-Null
Write-Ok "Sesion cerrada. Diagnostico finalizado."
