# MiXR — realidad mixta con la pantalla de tu PC en el aire

App nativa de iOS que usa la **cámara trasera como ventana al mundo real** y
pone **pantallas flotantes** encima: la pantalla de tu PC en vivo, videos o
páginas web. Las pantallas quedan ancladas al espacio (si te movés, siguen
donde las dejaste), se agrandan y se achican, y se pueden **controlar con la
mano** (hand tracking) como si fueran un mouse.

- **Realidad mixta horizontal (tipo visor)**: passthrough de cámara y ventanas
  ancladas al mundo en metros reales. Pensada para usarse apaisado, como un Quest.
- **Dos cámaras**: 0.5× ultra gran angular (~106° de campo) y 1× con ARKit (6DoF).
- **Manos con oclusión**: la mano **pasa por delante** de las ventanas, con los
  píxeles reales de la cámara, no con un dibujo.
- **Pantalla del PC**: stream H.264 de baja latencia (VideoToolbox) + mouse virtual.
- **Hand tracking**: Vision `VNDetectHumanHandPoseRequest`, 21 articulaciones por
  mano, hasta 2 manos, esqueleto con halo y yemas marcadas.
- **Ventanas**: PC, video (HLS/MP4 o de tu galería) y navegador web real (`WKWebView`).

```
Pinza (índice + pulgar) sobre una ventana  →  la agarra
Mové la mano                               →  la arrastra por el mundo
Pinza con las dos manos y separalas        →  agranda
Pinza con las dos manos y juntalas         →  achica
Modo Control + pinza                       →  clic en el PC
```

---

## 1. Cómo obtener el `.ipa` (sin Mac)

Compilar para iOS necesita el SDK de Apple, que solo existe en macOS. La
solución es GitHub Actions: un runner macOS compila y publica el archivo.

1. Creá un repositorio en GitHub (puede ser privado) y subí **el contenido de
   esta carpeta** (no la carpeta en sí): `project.yml`, `MiXR/`, `Support/`,
   `pc/`, `.github/`.

   ```bash
   cd MiXR-iOS
   git init
   git add .
   git commit -m "MiXR iOS"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/mixr-ios.git
   git push -u origin main
   ```

2. Entrá en **Actions → Build IPA → Run workflow** (también se dispara en cada
   push). Tarda ~5–10 minutos.

3. Cuando termine, abrí el run y descargá el artifact **`MiXR-ipa`**.
   Dentro está `MiXR.ipa`.

> El `.ipa` sale **sin firmar** (no se puede firmar sin tu cuenta de Apple).
> Eso es lo normal para instalar con Sideloadly / AltStore.

### Instalarlo en el iPhone

| Herramienta | Coste | Duración | Notas |
|---|---|---|---|
| **Sideloadly** (recomendado) | gratis | 7 días | Firma con tu Apple ID normal desde Windows/Mac |
| **AltStore / SideStore** | gratis | 7 días | Renueva sola en segundo plano |
| Cuenta de desarrollador (99 €/año) | pago | 1 año | Sin límite de 3 apps |

Pasos con Sideloadly (Windows):

1. Instalá Sideloadly e iTunes (o la app Apple Devices).
2. Conectá el iPhone, arrastrá `MiXR.ipa`, poné tu Apple ID.
3. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos** →
   confiá en tu certificado.
4. En iOS 16+ activá **Modo de desarrollador** (Ajustes → Privacidad y
   seguridad → Modo de desarrollador) y reiniciá.
5. Abrí la app y aceptá cámara + red local.

---

## 1.5. Los chips de arriba

| Chip | Qué hace |
|---|---|
| `0.5×` / `1×` | cambia de cámara: ultra gran angular (3DoF) o normal con ARKit (6DoF) |
| `Oclusión` | prende/apaga que la mano pase por delante de las ventanas |
| `⌖` | recentra el "adelante" (útil en 0.5× después de girar) |

El arrastre de ventanas usa el **dedo índice** como punto de control (no el
punto medio de la pinza, que se mueve solo al cerrar los dedos) y tolera que
Vision pierda la mano ~300 ms, así no se te suelta a mitad de camino.

---

## 2. Ver la pantalla de tu PC (3 pasos)

### Paso 1 — En el iPhone

Tocá **PC** en la barra de abajo. Aparece una ventana flotante que dice
`Esperando al PC… 192.168.x.x:47295`. Esa es la IP del iPhone y el puerto.

### Paso 2 — En el PC (mandar la pantalla)

Necesitás `ffmpeg` con `gdigrab` (build estándar de Windows):

```powershell
winget install Gyan.FFmpeg
```

Después, doble clic en **`pc\stream-pantalla.bat`** y escribí la IP del iPhone.
O a mano:

```powershell
ffmpeg -f gdigrab -framerate 60 -i desktop -vf "scale=-2:1080" `
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 60 `
  -bsf:v dump_extra -flush_packets 1 -f h264 tcp://192.168.x.x:47295
```

La pantalla aparece en el aire en 1–2 segundos.

| Ajuste | Para qué |
|---|---|
| `-framerate 60` | fluidez (bajá a 30 si el Wi-Fi sufre) |
| `scale=-2:1080` | resolución del stream (720, 1080, 1440…) |
| `-preset ultrafast` | mínima latencia de codificación |
| `-g 60` | keyframe por segundo: reconexión rápida |

### Paso 3 — Controlarla con la mano

En el PC, dejá corriendo el receptor de mouse:

```powershell
python pc\pc_input.py
```

(sin Python: `powershell -ExecutionPolicy Bypass -File pc\pc_input.ps1`)

En la app tocá **Control** (se pone verde) y listo:

- **El dedo índice mueve el cursor del PC.** Todo el cuadro de la cámara
  corresponde a toda la pantalla del PC: no hay que apuntar a la ventana.
- **Pinza (índice + pulgar) = clic izquierdo.** Mantené la pinza y mové la mano
  para arrastrar.
- La IP del PC se detecta sola cuando llega el stream; si no, la app te la pide.

> El script necesita que el Firewall de Windows le permita recibir UDP 47300
> (Windows pregunta la primera vez). Si el juego corre **como administrador**,
> ejecutá `pc_input.py` también como administrador.

---

## 3. Cosas que podés hacer con las ventanas

| Botón | Qué hace |
|---|---|
| **PC** | abre la pantalla del PC (escucha el stream) |
| **Video** | stream de ejemplo de Apple / cualquier `.m3u8` o `.mp4` |
| **Web** | navegador real (YouTube, Twitch, docs…) |
| **Fotos** | elige un video de tu galería |
| **Manos** | prende/apaga el tracking (y el esqueleto) |
| **Control** | la mano maneja el mouse del PC |
| **🗑 / 🔗** (arriba) | cerrar todas las ventanas / abrir una URL a mano |

Cada ventana: **✕** cierra y **🔗** cambia la URL (en la del PC no aparece,
porque su contenido lo manda el PC).

Tamaño y posición:

- **Con la mano**: pinza sobre la ventana y mové; con las dos manos en pinza,
  separar/juntar agranda/achica.
- **Con el dedo**: arrastrá desde la cabecera para moverla, pellizcá con dos
  dedos sobre la ventana para escalarla.

---

## 4. Cómo está hecho

```
project.yml                     proyecto XcodeGen (genera MiXR.xcodeproj)
Support/Info.plist              permisos (cámara, red local, ATS), vertical
MiXR/
  App/MiXRApp.swift             entry point SwiftUI
  App/RootView.swift            barra de controles + estado
  App/XRCameraView.swift        puente SwiftUI ↔ UIKit
  Core/Config.swift             constantes (distancias, puertos, límites)
  Core/XRSession.swift          orquesta ARKit + manos + ventanas + control
  RealityKit/                   migración al efecto Dreamspace (apagada por ahora)
    DreamspaceRenderer.swift    ARView + oclusión LiDAR + cielo + panel entidad
    SkyboxEntity.swift          cielo virtual como entidad (gradiente 2:1)
    RealityPanelEntity.swift    panel como entidad con textura generada
  Hand/HandTracker.swift        Vision: 21 puntos → pantalla (con suavizado)
  Hand/HandOverlayView.swift    esqueleto + retícula, CAShapeLayer
  Hand/GestureEngine.swift      pinza → agarrar / escalar ventanas
  PC/InputClient.swift          UDP de eventos de mouse al PC
  PC/PointerController.swift    dedo índice + pinza → cursor y clic
  Stream/H264Assembler.swift    NALs → CMSampleBuffer (VideoToolbox)
  Stream/H264StreamParser.swift flujo TCP → frames (Annex B o largo+NAL)
  Stream/StreamServer.swift     NWListener TCP + decodificación
  Stream/LocalIP.swift          IP Wi-Fi del iPhone (en0)
  Windows/SpatialWindow.swift   modelo: tipo, posición 3D, ancho en metros
  Windows/WindowHostView.swift  proyección mundo→pantalla cada frame
  Windows/SpatialWindowView.swift  tarjeta de cristal + cabecera + gestos
  Windows/StreamContentView.swift  AVSampleBufferDisplayLayer + ayuda
  Windows/VideoContentView.swift   AVPlayerLayer
  Windows/WebContentView.swift     WKWebView
pc/pc_input.py                  mouse virtual (Windows, sin dependencias)
pc/pc_input.ps1                 lo mismo en PowerShell
pc/stream-pantalla.bat          lanza ffmpeg apuntando al iPhone
.github/workflows/build-ipa.yml compila y publica el .ipa
```

### Las tres matemáticas

**1. Ventanas en el mundo.** Cada ventana guarda una posición en metros en el
espacio de ARKit. En cada frame se proyecta con `ARCamera.projectPoint` y se
calcula cuántos puntos de pantalla mide un metro a esa profundidad:

```
escala = (proyección vertical) * altoPantalla / 2 / profundidad
anchoEnPantalla = anchoFísico(metros) * escala
```

Se aplica como `transform`: la ventana se ve más chica cuanto más lejos y se
queda quieta en el aire cuando movés el teléfono (paralaje real). Al
arrastrarla, los puntos de pantalla vuelven a metros con esa misma escala.

**2. Manos.** Vision devuelve 21 puntos normalizados; se pasan a coordenadas de
pantalla con el mismo recorte "aspect fill" que usa la cámara, se suavizan por
articulación y se calcula la pinza con la fórmula del port de MediaPipe
(`1 - distancia(pulgar, índice) / tamañoMano / 0.9`, con histéresis).

**3. Mouse.** El índice se mapea a `0…1` del cuadro de cámara y se manda como
`uint16` en un datagrama UDP al PC, que hace `SetCursorPos`. La pinza manda
botón abajo/arriba. Si se pierde la mano, se suelta el botón (nunca queda
pegado).

### Migración a RealityKit (efecto Dreamspace)

La app está migrando de SceneKit a RealityKit por partes. El **commit 1** deja
todo armado pero **apagado**: con `XRSession.useRealityKit = false` la app
funciona exactamente como antes (`ARSCNView`) y no se crea ninguna `ARView`.

Con el interruptor en `true`:

| Pieza | Qué hace |
|---|---|
| `ARView` | reemplaza al `ARSCNView` y comparte el **mismo** `ARSession` (una cámara, un tracking, las manos siguen leyendo `currentFrame`) |
| `sceneReconstruction = .meshWithClassification` | malla del LiDAR de la habitación (ya se pedía en la configuración) |
| `environment.sceneUnderstanding.options = .occlusion` | los objetos reales tapan lo virtual |
| `SkyboxEntity` | cielo virtual pegado a la cámara: esfera de 8 m con un gradiente de prueba |
| `RealityPanelEntity` | panel de prueba como entidad, con la textura generada en runtime |

Para probarlo: poner `useRealityKit` en `true` en `Core/XRSession.swift`,
compilar y apuntar a una mesa o pasar la mano delante del panel: el panel
desaparece detrás de lo real. En un iPhone sin LiDAR no hay malla y por lo
tanto no hay oclusión (el resto sí funciona).

El cielo es una **entidad** y no `environment.background = .skybox(…)` a
propósito: generar un `EnvironmentResource` desde una imagen en runtime cambia
entre versiones del SDK, mientras que una esfera invertida compila igual en
iOS 16+ y se puede reemplazar por un modelo o una imagen real sin tocar el
resto.

Falta para los próximos commits: mover las ventanas de UIKit a entidades
(textura en vivo del stream en un `VideoMaterial`), llevar el arrastre con las
manos a `Entity.position` y decidir si el fondo queda en el feed de la cámara
o si el cielo lo reemplaza.

---

## 5. Limitaciones honestas

- **Horizontal, como un visor**: la app corre apaisada (soporta las dos
  orientaciones y también vertical por si la agarrás así). Todo el mapeo de
  manos y la proyección de ventanas se recalculan según la orientación.
- **0.5× tiene 3DoF, no 6DoF**: ARKit no deja usar la ultra gran angular, así
  que ese modo usa CoreMotion. Ganás campo de visión (manos y mundo), perdés el
  anclaje por traslación: las ventanas giran con vos pero no quedan clavadas si
  caminás. Con el botón **⌖** volvés a poner "adelante" donde estás mirando.
- **La oclusión de manos es geométrica**: recorta la imagen de la cámara con la
  silueta de la mano (dedos + palma). Es muy convincente de frente, pero si la
  mano está muy de perfil la silueta puede quedar corta. Se apaga con el chip
  **Oclusión**.
- **Manos sin profundidad**: Vision da 21 puntos 2D; la pinza se calcula por
  distancia normalizada. Funciona mejor con buena luz y de frente.
- **El control es del escritorio, no inyección en juegos**: usa `SetCursorPos` +
  `mouse_event`. Juegos con anti-cheat o que piden raw input pueden ignorarlo;
  los que corren como administrador necesitan el script elevado.
- **Sin audio del PC** todavía (el stream es solo video).
- **Latencia**: en Wi-Fi 5 GHz ronda 40–80 ms; en 2,4 GHz se nota.
- **Batería**: cámara + ARKit + Vision a 24 Hz + decodificar video calienta.
- **7 días**: con Apple ID gratuito la app deja de abrirse a los 7 días. Se
  renueva volviendo a firmar.

---

## 6. Problemas típicos

| Síntoma | Causa / solución |
|---|---|
| "Esperando al PC…" y no pasa nada | IP equivocada, firewalls, o el PC no está en la misma red |
| `Connection refused` en ffmpeg | la ventana **PC** no está abierta, o cambió la IP del iPhone |
| Se ve congelado / pixelado | bajá a `-framerate 30` y `scale=-2:720`, o pasate a 5 GHz |
| Pantalla negra con el stream conectado | el PC no manda SPS/PPS: agregá `-bsf:v dump_extra` (ya está en el .bat) |
| El cursor no se mueve | falta `pc_input.py` corriendo, o el Firewall bloquea UDP 47300 |
| El cursor se mueve pero el clic no | el juego corre como admin → corré el script como admin |
| Las manos no aparecen | poca luz, mano fuera de cuadro, o botón **Manos** apagado |
| Las ventanas tiemblan | ARKit perdiendo tracking: más luz y texturas |
| Build rojo en Actions | mirá el artifact `xcodebuild-log` |

---

## 7. Compilar con Mac (alternativa)

```bash
brew install xcodegen
xcodegen generate
open MiXR.xcodeproj
```

Elegí tu equipo en *Signing & Capabilities*, conectá el iPhone y ejecutá.
El bundle id por defecto es `com.mixr.ios` (cambialo si te da conflicto).
