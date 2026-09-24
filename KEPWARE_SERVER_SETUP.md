# Kepware Server local con la estructura HMI

Esta guía describe la instalación de KEPServerEX 6.18 y la creación de un servidor
OPC UA local basado en los exports de tags incluidos en este repositorio.

El objetivo es disponer de un servidor industrial independiente, no de un servidor
implementado con `asyncua`. Kepware utiliza su driver `Simulator` como dispositivo
PLC virtual y publica los tags mediante su interfaz OPC UA.

## Resultado esperado

- Producto: KEPServerEX 6.18.318.0.
- Driver: `Simulator`.
- Canal predeterminado: `HMI_Simulator`.
- Dispositivo predeterminado: `PLC`.
- Endpoint OPC UA local: `opc.tcp://127.0.0.1:49320`.
- 319 nodos exportados procesados.
- 292 variables escalares creadas como tags.
- Los nodos de tipos PLC personalizados se representan como grupos.
- `HMI_Out` se publica con acceso de cliente de solo lectura.
- `HMI_IN` se publica con acceso de lectura y escritura.

Kepware genera sus propios NodeIds a partir de la jerarquía
`canal.dispositivo.grupos.tag`. No puede conservar literalmente los NodeIds
`ns=3;s=...` del servidor Siemens original. El script genera un CSV que relaciona
cada NodeId original con su Item ID en Kepware.

## Requisitos

- Windows 10, Windows 11 o Windows Server compatible.
- PowerShell 7 para aceptar el certificado HTTPS local mediante
  `-TrustLocalCertificate`.
- Permisos de administrador para instalar Kepware y habilitar o deshabilitar su API.
- Los archivos siguientes en la raíz del repositorio:
  - `HMI_TAGS_TO_READ_OPC_UA_REAL_DATA_STRUCTURE`
  - `HMI_TAGS_TO_WRITE_OPC_UA_REAL_DATA_STRUCTURE`

## Instalación realizada

Se instaló el paquete de evaluación:

```text
KEPServerEX6-6.18.318.0.exe
```

La firma Authenticode se verificó antes de ejecutarlo:

```text
Firmante: PTC Inc.
Estado: Valid
SHA-256: 7BDEBF7EC329A41767B93E01B20A4EFDABDAC311343C3929EAC651D9B192D434
```

El instalador se ejecutó elevado y en modo silencioso:

```powershell
Start-Process `
  -FilePath ".\KEPServerEX6-6.18.318.0.exe" `
  -ArgumentList @("/qn", "/e", "ACCEPT_EULA=YES") `
  -Verb RunAs `
  -Wait
```

La instalación de evaluación es funcional durante dos horas por ejecución. Se puede
volver a iniciar el periodo deteniendo y arrancando el Runtime.

## Comprobación de la instalación

```powershell
Get-ItemProperty `
  "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
  Where-Object DisplayName -eq "KEPServerEX 6" |
  Select-Object DisplayName, DisplayVersion, InstallLocation, Publisher
```

Servicios observados después de la instalación:

| Servicio | Función | Inicio esperado |
| --- | --- | --- |
| `KEPServerEXV6` | Runtime OPC | Automático y en ejecución |
| `KEPServerEXConfigAPI6` | API de configuración | Automático y en ejecución |
| `KEPServerEXLoggerV6` | Registro de eventos | Automático y en ejecución |
| `KEPServerEXKeySvcV6` | Licencias | Manual y en ejecución |
| `KEPServerEXStoreAndForwardV6` | Store and Forward | Manual; puede estar detenido |

Para consultarlos:

```powershell
Get-Service KEPServerEX* | Select-Object Status, Name, StartType
```

## Preparar el usuario Administrator

La instalación silenciosa no establece una contraseña administrativa. Antes de usar
la API:

1. Abre **KEPServerEX 6 Administration**.
2. Entra en **Settings > User Manager**.
3. Establece una contraseña para `Administrator`.
4. Usa al menos 14 caracteres y no guardes la contraseña en el repositorio.

El script solicita las credenciales con `Get-Credential`; no acepta ni almacena una
contraseña en texto plano.

## Generar la configuración sin modificar Kepware

Desde la raíz del repositorio:

```powershell
pwsh -NoProfile -File .\tools\Configure-KepwareSimulator.ps1 -Mode Generate
```

Esto crea en el directorio actual del script:

- `kepware-project-payload.json`: cuerpo JSON para la API de Kepware.
- `kepware-tag-map.csv`: correspondencia de NodeId, ruta, tipo, acceso, dirección de
  simulación e Item ID de Kepware.

Se puede elegir otro directorio de salida:

```powershell
.\tools\Configure-KepwareSimulator.ps1 `
  -Mode Generate `
  -OutputDirectory C:\Temp\kepware-preview
```

## Habilitar la API local

Abre PowerShell 7 como administrador y revisa primero el cambio:

```powershell
.\tools\Configure-KepwareSimulator.ps1 -Mode EnableApi -WhatIf
```

Después aplícalo:

```powershell
.\tools\Configure-KepwareSimulator.ps1 -Mode EnableApi
```

El script:

- solo admite un host loopback: `127.0.0.1`, `localhost` o `::1`;
- modifica únicamente `Enabled` en la sección `[Config API Service]`;
- guarda una copia en
  `C:\ProgramData\Kepware\KEPServerEX\V6\settings.ini.before-codex-config-api`;
- reinicia únicamente el servicio `KEPServerEXConfigAPI6`.

La API HTTPS predeterminada queda en:

```text
https://127.0.0.1:57512/config/v1
```

## Importar el modelo

```powershell
$credential = Get-Credential -UserName Administrator

.\tools\Configure-KepwareSimulator.ps1 `
  -Mode Import `
  -Credential $credential `
  -TrustLocalCertificate
```

El certificado de la API es local y autofirmado. `-TrustLocalCertificate` desactiva
la validación del certificado únicamente para las peticiones realizadas por ese
proceso de PowerShell y únicamente se admite un endpoint loopback.

Si el canal ya existe, el script se detiene. Para reemplazar exclusivamente el canal
indicado, revisa primero la operación:

```powershell
.\tools\Configure-KepwareSimulator.ps1 `
  -Mode Import `
  -Credential $credential `
  -TrustLocalCertificate `
  -ReplaceExistingChannel `
  -WhatIf
```

Quita `-WhatIf` después de comprobar el nombre del canal.

## Ejecución completa

Este modo habilita la API, importa el modelo y vuelve a deshabilitar la API:

```powershell
$credential = Get-Credential -UserName Administrator

.\tools\Configure-KepwareSimulator.ps1 `
  -Mode All `
  -Credential $credential `
  -TrustLocalCertificate
```

Para conservar la API habilitada, añade `-KeepApiEnabled`. No es recomendable salvo
que otra herramienta local necesite administrarla continuamente.

## Parámetros principales

| Parámetro | Valor predeterminado | Descripción |
| --- | --- | --- |
| `Mode` | `Generate` | `Generate`, `EnableApi`, `DisableApi`, `Import` o `All` |
| `RepositoryPath` | raíz esperada en `C:\Projects\opcua-asyncio` | Ubicación de los exports |
| `ChannelName` | `HMI_Simulator` | Canal creado en Kepware |
| `DeviceName` | `PLC` | Dispositivo Simulator |
| `DeviceId` | `1` | ID Simulator, entre 1 y 999 |
| `DeviceModel` | `1` | Modelo Simulator de 16 bits |
| `ApiBaseUri` | `https://127.0.0.1:57512/config/v1` | API, limitada a loopback |
| `OutputDirectory` | directorio del script | Salida JSON y CSV |
| `ReplaceExistingChannel` | desactivado | Sustituye solo el canal indicado |
| `KeepApiEnabled` | desactivado | No deshabilita la API tras `All` |

Ejemplo con nombres diferentes:

```powershell
$credential = Get-Credential -UserName Administrator

.\tools\Configure-KepwareSimulator.ps1 `
  -Mode All `
  -RepositoryPath D:\repos\opcua-asyncio `
  -ChannelName HMI_Local `
  -DeviceName PLC_Simulado `
  -DeviceId 2 `
  -Credential $credential `
  -TrustLocalCertificate
```

## Asignación de datos

| Tipo exportado | Tipo Kepware | Dirección Simulator |
| --- | --- | --- |
| `Boolean` | Boolean | `B1`, `B2`, ... |
| `Int16` | Short | `K1`, `K2`, ... |
| `UInt16` | Word | `K1`, `K2`, ... |
| `String` | String | `S1`, `S2`, ... |

Los registros `K` evitan que los valores numéricos cambien automáticamente durante
las lecturas. Los registros `B`, `K` y `S` del driver Simulator admiten escritura; el
permiso visible para el cliente se restringe adicionalmente mediante
`servermain.TAG_READ_WRITE_ACCESS`.

Los nombres de arrays se normalizan porque Kepware genera sus propios identificadores:

```text
"PickOrder"[0] -> PickOrder_0
```

Ejemplo de correspondencia completa:

```text
ns=3;s="HMI_Out"."Cell"."AllowTray_1Removed"
HMI_Simulator.PLC.HMI_Out.Cell.AllowTray_1Removed
```

## Verificación desde un cliente OPC UA

1. Conecta a `opc.tcp://127.0.0.1:49320`.
2. Acepta o confía en el certificado local del servidor.
3. Navega a `HMI_Simulator > PLC > HMI_Out` y comprueba una lectura.
4. Navega a `HMI_Simulator > PLC > HMI_IN` y comprueba una escritura.
5. Confirma que Kepware rechaza la escritura sobre un tag de `HMI_Out`.

La configuración OPC UA predeterminada instalada exige
`Basic256Sha256 / Sign & Encrypt`. Cambiar políticas, certificados, usuarios o exponer
el puerto fuera de localhost debe tratarse como una decisión de seguridad separada.

## Restauración

Para deshabilitar la API sin tocar el proyecto:

```powershell
.\tools\Configure-KepwareSimulator.ps1 -Mode DisableApi
```

Para restaurar manualmente el archivo previo, detén primero
`KEPServerEXConfigAPI6`, copia el archivo `.before-codex-config-api` sobre
`settings.ini` y vuelve a iniciar el servicio.

El script nunca desinstala Kepware, elimina otros canales ni cambia la configuración
de seguridad OPC UA. `-ReplaceExistingChannel` solo actúa sobre el canal cuyo nombre
se pasa en `-ChannelName`.

## Referencias

- [Kepware Configuration API](https://support.ptc.com/help/kepware/kepware_server/en/kepware/server/config-api-service.html)
- [Creación de canales mediante la API](https://support.ptc.com/help/kepware/kepware_server/en/kepware/server/config-api-create-channel.html)
- [Creación de tags mediante la API](https://support.ptc.com/help/kepware/kepware_server/en/kepware/server/config-api-create-tag.html)
- [Direccionamiento del driver Simulator](https://support.ptc.com/help/kepware/drivers/en/kepware/drivers/SIMULATOR/address-descriptions.html)
