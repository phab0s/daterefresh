<#
.SYNOPSIS
    Vault local cifrado (DPAPI) para los secrets de GitHub del workflow.

.DESCRIPTION
    Guarda los 7 secrets del workflow en un archivo .vault.enc cifrado con DPAPI
    (Data Protection API de Windows). El cifrado esta ligado a tu usuario de
    Windows actual: SOLO TU, en ESTE equipo, puedes descifrarlo.

    El archivo NUNCA debe subirse al repositorio (esta en .gitignore).

    Comandos:
        save    Pide cada secret por prompt seguro (entrada oculta) y lo guarda
                cifrado en diagnostic/.vault.enc
        show    Descifra y muestra todos los secrets en pantalla
        get     Descifra y muestra UN solo secret:  pwsh Secrets-Vault.ps1 get MS_GRAPH_USER_EMAIL
        copy    Descifra UN secret y lo copia al portapapeles: pwsh Secrets-Vault.ps1 copy MS_GRAPH_USER_EMAIL
        github  Genera comandos `gh secret set ...` listos para ejecutar (necesita GitHub CLI)

    Los 7 secrets soportados:
        AZURE_CLIENT_ID
        AZURE_TENANT_ID
        MS_GRAPH_USER_EMAIL
        MS_TEAMS_TEAM_ID
        SHAREPOINT_SITE_ID
        POWER_AUTOMATE_HTTP_TRIGGER_URL
        TEAMS_WEBHOOK_URL

.EXAMPLE
    pwsh .\diagnostic\Secrets-Vault.ps1 save
    pwsh .\diagnostic\Secrets-Vault.ps1 show
    pwsh .\diagnostic\Secrets-Vault.ps1 copy MS_GRAPH_USER_EMAIL
    pwsh .\diagnostic\Secrets-Vault.ps1 github
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('save','show','get','copy','github')]
    [string]$Action = 'save',

    [Parameter(Position = 1)]
    [string]$Name
)

$ErrorActionPreference = 'Stop'

# Ruta absoluta del vault (siempre junto al script)
$VaultPath = Join-Path $PSScriptRoot '.vault.enc'

# Lista canonica de secrets del workflow auto-activity.yml
$SecretNames = @(
    'AZURE_CLIENT_ID',
    'AZURE_TENANT_ID',
    'MS_GRAPH_USER_EMAIL',
    'MS_TEAMS_TEAM_ID',
    'SHAREPOINT_SITE_ID',
    'POWER_AUTOMATE_HTTP_TRIGGER_URL',
    'TEAMS_WEBHOOK_URL'
)

$Help = [ordered]@{
    'AZURE_CLIENT_ID'                 = 'Id. de aplicacion (cliente) de la App Registration en Entra ID (GUID).'
    'AZURE_TENANT_ID'                 = 'Tenant ID de Entra ID (GUID).'
    'MS_GRAPH_USER_EMAIL'             = 'UPN del usuario E5. Formato: algo@dominio.onmicrosoft.com. Mira outlook.office.com o Entra ID > Usuarios.'
    'MS_TEAMS_TEAM_ID'                = 'ID del equipo de Teams (GUID). Graph Explorer: GET /me/joinedTeams'
    'SHAREPOINT_SITE_ID'              = 'ID del sitio SharePoint en formato Graph: dominio,siteGuid,collectionGuid. Graph Explorer: GET /sites?search=*'
    'POWER_AUTOMATE_HTTP_TRIGGER_URL' = 'URL del trigger HTTP del flow en Power Automate (contiene SAS key).'
    'TEAMS_WEBHOOK_URL'               = 'URL del webhook entrante del canal de Teams.'
}

function Write-Section($t) {
    Write-Host ""
    Write-Host "=== $t ===" -ForegroundColor Cyan
}
function Write-Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info($m){ Write-Host "  [i]    $m" -ForegroundColor DarkGray }

function Read-ExistingVault {
    if (-not (Test-Path $VaultPath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($VaultPath)
        $json  = [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser))
        return $json | ConvertFrom-Json
    } catch {
        Write-Bad "No se pudo descifrar el vault (¿otro usuario o PC?): $($_.Exception.Message)"
        return $null
    }
}

function Write-Vault($data) {
    $json  = ($data | ConvertTo-Json -Depth 5)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($VaultPath, $enc)
    # Permisos restrictivos: solo el usuario actual
    try {
        $acl = Get-Acl $VaultPath
        $acl.SetAccessRuleProtection($true, $false)  # deshereda
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl','Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $VaultPath -AclObject $acl
    } catch {
        Write-Warn2 "No se pudo ajustar ACL del vault: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
switch ($Action) {

    'save' {
        Write-Section "Guardar secrets en vault cifrado (DPAPI)"
        Write-Host "  Vault: $VaultPath" -ForegroundColor DarkGray
        Write-Host "  Cifrado ligado a: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) en ESTE PC." -ForegroundColor DarkGray
        Write-Host ""

        $existing = Read-ExistingVault
        if ($existing) {
            Write-Warn2 "Ya existe un vault. Se conservaran los valores que dejes vacios (Enter)."
        }

        $data = if ($existing) { $existing } else { [ordered]@{} }

        foreach ($name in $SecretNames) {
            $hint = $Help[$name]
            $current = if ($existing.$name) {
                $v = [string]$existing.$name
                if ($v.Length -gt 6) { $v.Substring(0,3) + ('*' * ($v.Length - 6)) + $v.Substring($v.Length - 3) }
                else { '***' }
            } else { $null }
            $suffix = if ($current) { "  [actual: $current — Enter para mantener]" } else { '' }
            Write-Host ""
            Write-Host "  $name" -ForegroundColor White
            Write-Host "    $hint" -ForegroundColor DarkGray
            $val = Read-Host -Prompt "    Valor$suffix" -AsSecureString
            $plain = [System.Net.NetworkCredential]::new('', $val).Password
            if ([string]::IsNullOrEmpty($plain)) {
                if ($existing.$name) { Write-Info "Se conserva el valor existente." }
                else { Write-Warn2 "Vacio y sin valor previo. Se guardara vacio." ; $data.$name = '' }
            } else {
                $data.$name = $plain.Trim()
                Write-Ok "Guardado."
            }
        }

        Write-Vault $data
        Write-Host ""
        Write-Ok "Vault guardado: $VaultPath"
        Write-Info "Recuerda: solo TU usuario en ESTE PC puede descifrarlo."
        Write-Info "Para ver todo:      pwsh `"$PSCommandPath`" show"
        Write-Info "Para copiar uno:    pwsh `"$PSCommandPath`" copy MS_GRAPH_USER_EMAIL"
        Write-Info "Para GitHub CLI:    pwsh `"$PSCommandPath`" github"
    }

    'show' {
        Write-Section "Mostrar secrets del vault"
        $data = Read-ExistingVault
        if (-not $data) { Write-Bad "No existe vault en $VaultPath. Ejecuta 'save' primero." ; exit 1 }
        foreach ($name in $SecretNames) {
            $v = $data.$name
            if ($null -eq $v -or $v -eq '') { Write-Host "  $name = (vacio)" -ForegroundColor Yellow }
            else { Write-Host "  $name = $v" }
        }
    }

    { $_ -in 'get','copy' } {
        if (-not $Name) { Write-Bad "Indica el nombre del secret: pwsh `"$PSCommandPath`" $Action MS_GRAPH_USER_EMAIL" ; exit 1 }
        if ($Name -notin $SecretNames) { Write-Bad "'$Name' no es uno de los secrets conocidos: $($SecretNames -join ', ')" ; exit 1 }
        $data = Read-ExistingVault
        if (-not $data) { Write-Bad "No existe vault." ; exit 1 }
        $v = $data.$Name
        if ($Action -eq 'get') {
            Write-Host "$Name = $v"
        } else {
            Set-Clipboard -Value $v
            Write-Ok "$Name copiado al portapapeles."
        }
    }

    'github' {
        Write-Section "Generar comandos para GitHub CLI (gh secret set)"
        $data = Read-ExistingVault
        if (-not $data) { Write-Bad "No existe vault. Ejecuta 'save' primero." ; exit 1 }
        # El repo se deduce del remote de git si es posible
        $repo = $null
        try {
            $remote = git -C $PSScriptRoot remote get-url origin 2>$null
            if ($remote -match 'github\.com[:/]([^/]+/[^/]+?)(\.git)?$') { $repo = $Matches[1] }
        } catch {}
        if (-not $repo) { $repo = 'phab0s/daterefresh' ; Write-Warn2 "No se dedujo el repo del remote. Usando '$repo' (ajusta si es otro)." }

        Write-Host "  Repo: $repo" -ForegroundColor DarkGray
        Write-Host "  Requisito: tener GitHub CLI instalado y autenticado (gh auth login)." -ForegroundColor DarkGray
        Write-Host ""
        $hasGh = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
        if (-not $hasGh) { Write-Warn2 "GitHub CLI (gh) NO esta instalado. Puedes instalarlo: winget install --id GitHub.cli" }

        foreach ($name in $SecretNames) {
            $v = $data.$name
            if ([string]::IsNullOrEmpty($v)) { Write-Warn2 "$name esta VACIO en el vault. Saltando." ; continue }
            # Usamos lectura desde stdin para que el valor no aparezca en el historial de shell
            $cmd = "gh secret set $name --repo `"$repo`" --body `"<valor>`""
            Write-Host "  # $name" -ForegroundColor DarkGray
            Write-Host "  pwsh -Command `"gh secret set $name --repo '$repo' -b ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host -AsSecureString))))`"" -ForegroundColor Green
        }
        Write-Host ""
        Write-Info "Cada linea pega el valor de forma oculta y NO queda en el historial."
        Write-Info "Alternativa mas simple: copia cada valor con 'pwsh `"$PSCommandPath`" copy <NAME>' y pegalo en"
        Write-Info "  https://github.com/$repo/settings/secrets/actions"
    }
}

Write-Host ""
