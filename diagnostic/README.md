# Diagnóstico: `ErrorInvalidUser` (HTTP 404) en Microsoft Graph

## El problema

El workflow `.github/workflows/auto-activity.yml` falla en el paso **10**:

```
POST https://graph.microsoft.com/v1.0/users/$USER_EMAIL/calendar/events
HTTP 404  {"code":"ErrorInvalidUser","message":"The requested user '...' is invalid."}
```

## Causa raíz (lectura del error)

**No es un problema de `Mail.Send`.** Un error de permisos habría sido `HTTP 403` con
`Authorization_RequestDenied` o `ErrorAccessDenied`.

Un **`HTTP 404 ErrorInvalidUser`** significa que Graph resolvió el token correctamente
(los pasos de Teams y SharePoint funcionaron antes) pero **no puede resolver el
identificador `$USER_EMAIL` como un buzón válido/accesible**.

Las causas posibles, en orden de probabilidad:

| # | Causa | Síntoma en el script |
|---|-------|----------------------|
| **A** | El secret `MS_GRAPH_USER_EMAIL` está vacío, mal copiado o con salto de línea | Sección 2 falla |
| **B** | El usuario perdió su buzón de Exchange (licencia E5 caducada) | Sección 4 y 5 fallan, 3 OK |
| **C** | El UPN cambió, o el mailbox está inactivo/hard-deleted | Sección 3 muestra UPN distinto |
| **D** | El Service Principal no tiene los permisos correctos (daría 403, pero se verifica por descarte) | Sección 7 |

## Uso del script `Check-GraphUser.ps1`

Requiere PowerShell 7+ (`pwsh`) y permisos de administrador del tenant para iniciar
sesión de forma interactiva.

```powershell
# Desde la carpeta diagnostic/
pwsh .\Check-GraphUser.ps1 -UserEmail "usuario@tudominio.onmicrosoft.com"
```

Para inspeccionar también los permisos del Service Principal de la app:

```powershell
pwsh .\Check-GraphUser.ps1 `
  -UserEmail "usuario@tudominio.onmicrosoft.com" `
  -AppClientId "11111111-2222-3333-4444-555555555555"
```

El script instala automáticamente `Microsoft.Graph.Authentication` si falta.

## Checklist (alternativa rápida, sin PowerShell)

### En GitHub
1. **Settings → Secrets and variables → Actions** → abrir `MS_GRAPH_USER_EMAIL`.
2. Comprobar que el valor es exactamente el **UPN** (no el objectId GUID, no el alias).
3. Asegurar que **no hay espacios, comillas ni saltos de línea** al inicio o final.
4. Re-pegar el valor limpio si hay duda.

### En Entra ID (Azure AD)
1. **Usuarios → {usuario}** → comprobar que está **habilitado** y el **UPN coincide** con el secret.
2. **Usuarios → {usuario} → Licencias** → comprobar que el plan **Microsoft 365 E5 (Developer)**
   está asignado y activo (si la suscripción del programa Developer caducó, el buzón
   se elimina temporalmente y `/calendar` responde 404).
3. **Aplicaciones empresariales → {tu app} → Permisos** → confirmar consentimiento de
   admin para `Calendars.ReadWrite`, `Mail.Send`, `User.Read.All`.

## Nota sobre `Mail.Send`

`Mail.Send` solo se usa en los pasos **12** y **20** del workflow (`sendMail`).
El error actual ocurrió en el paso **10** (calendario), que depende de `Calendars.ReadWrite`,
no de `Mail.Send`. Si tras arreglar el calendario el paso 12 empezara a fallar con 403,
**ahí sí** sería momento de revisar `Mail.Send`. Pero no es el caso actual.
