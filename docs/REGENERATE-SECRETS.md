# Guía para regenerar los 7 secrets del workflow

Tu workflow `.github/workflows/auto-activity.yml` usa **7 secrets** de GitHub. Esta
guía te dice dónde encontrar **cada valor** y cómo guardarlo de forma segura.

> ⚠️ **REGLA DE ORO:** nunca pegues un valor secreto en el chat, en un commit, ni en
> ningún archivo del repo. Pégalo directamente en GitHub o en el vault local cifrado.

## Paso 0 — Dónde pegarlos en GitHub

1. https://github.com/phab0s/daterefresh/settings/secrets/actions
2. Para cada secret: **New repository secret** (o edita el existente).
3. Nombre = el de la columna izquierda. Value = el valor que encuentres abajo.

---

## 1. `AZURE_TENANT_ID` (ID del directorio)

- https://entra.microsoft.com → **Identidad → Información general → Tenant ID**
- O en la URL del portal: `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/TenantOverview.ReactView` → aparece "Tenant ID".
- Formato: GUID tipo `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee`.

## 2. `AZURE_CLIENT_ID` (Application ID de la app)

- https://entra.microsoft.com → **Aplicaciones → Registros de aplicaciones** →
  busca la app que usa el workflow (suele llamarse algo como "GitHub Actions E5"
  o el nombre de tu proyecto).
- En su página de **Información general**, copia **Id. de aplicación (cliente)**.
- Formato: GUID.

> Como usaste **OIDC (federación con GitHub)**, NO necesitas ningún client secret.
> Solo `AZURE_CLIENT_ID` + `AZURE_TENANT_ID` + la federación configurada en la app.
>
> Para confirmar que la federación sigue activa:
> App → **Certificados y secretos → Federaciones**. Debe haber una entrada con
> Issuer `https://token.actions.githubusercontent.com` y Subject
> `repo:phab0s/daterefresh:ref:refs/heads/main` (o `environment:Production`).

## 3. `MS_GRAPH_USER_EMAIL` (UPN del usuario E5 — el del error 404)

Este es el que estaba mal. Para encontrar el UPN correcto:

- https://outlook.office.com → inicia sesión con la cuenta E5 del developer program.
  El correo con el que entras **es** el UPN.
- Confírmalo mirando Entra ID → **Identidad → Usuarios → Todos los usuarios**.
  La columna **"Nombre principal de usuario"** es el UPN que debe ir aquí.
- Suelo formato: `algo@tudominio.onmicrosoft.com` (o dominio personalizado).

> 💡 Truco extra: revisa la bandeja de Outlook y busca correos con asunto
> "Resumen Actividad E5 - ..." o "Pipeline E5 Completado". Si los ves, es la
> cuenta correcta (los generó tu propio workflow).

## 4. `MS_TEAMS_TEAM_ID` (ID del equipo de Teams)

- https://entra.microsoft.com o Graph Explorer: obtén el ID del equipo.
- Forma sencilla con Graph Explorer (https://developer.microsoft.com/graph/graph-explorer):
  1. Inicia sesión con la cuenta E5.
  2. GET `https://graph.microsoft.com/v1.0/me/joinedTeams`
  3. Copia el `id` del equipo que tenga el canal "GitHub-Activity-Log".
- Formato: GUID.

## 5. `SHAREPOINT_SITE_ID` (ID del sitio SharePoint)

⚠️ Ojo: Graph usa el formato `dominio,sitio,collection-id`, **no** el ID corto.

- Graph Explorer: GET `https://graph.microsoft.com/v1.0/sites?search=*`
- El `id` devuelto tiene forma `tudominio.sharepoint.com,guid-sitio,guid-coleccion`.
- Copia **esa cadena completa** (con las comas) como valor del secret.

## 6. `POWER_AUTOMATE_HTTP_TRIGGER_URL` (URL del trigger HTTP)

- https://make.powerautomate.com → **Mis flujos** → abre el flow que usa el workflow.
- En el paso inicial **"Cuando se reciba una solicitud HTTP"**, copia la
  **URL de HTTP POST**.
- ⚠️ Contiene una **clave SAS** (parámetro `sig` o `sv`). Es sensible: **no la
  compartas ni la pegues en el chat**.
- Si perdiste el flow o quieres rotar la clave, crea uno nuevo y copia la nueva URL.

## 7. `TEAMS_WEBHOOK_URL` (Webhook entrante del canal)

- Abre Microsoft Teams → el equipo/canal de logs → **... → Conectores** o
  **Administrar canal → Webhooks entrantes**.
- Si ya existe el webhook, copia su URL. Si no, crea uno nuevo llamado
  "GitHub Actions".
- Formato: `https://tudominio.webhook.office.com/webhookb2/...`.
- ⚠️ Es sensible (cualquiera con la URL puede enviar mensajes). Si la filtraste,
  elimínala y crea una nueva.

---

## Verificación tras actualizar todo

1. En GitHub: https://github.com/phab0s/daterefresh/actions
2. Selecciona el workflow **"Desarrollo de Proyecto 365"**.
3. **Run workflow** (botón manual, gracias a `workflow_dispatch: {}`).
4. Observa los logs. Si el paso 10 (Calendario Outlook) pasa de 404 a ✅, está arreglado.
5. Para validar los permisos de Graph, ejecuta también:
   ```powershell
   pwsh .\diagnostic\Check-GraphUser.ps1 -UserEmail "<UPN>" -AppClientId "<AZURE_CLIENT_ID>"
   ```

## Copia de seguridad local (cifrado DPAPI)

Tras pegar todos los valores en GitHub, guárdalos también cifrados en tu PC con:

```powershell
pwsh .\diagnostic\Secrets-Vault.ps1 save
# te pedirá cada valor por prompt seguro y los cifra con DPAPI (ligado a tu usuario/PC)
```

Para recuperarlos más adelante:

```powershell
pwsh .\diagnostic\Secrets-Vault.ps1 show
```

El archivo `.vault.enc` queda **fuera del repo** (ignorado por `.gitignore`) y solo
puedes descifrarlo tú, en este equipo, con tu sesión de Windows.
