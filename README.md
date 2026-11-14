# MiXR — realidad mixta en el iPhone

App nativa de iOS que usa la **cámara trasera como ventana al mundo real** y
pone **ventanas flotantes** encima (videos, páginas web), ancladas al espacio:
si te movés, las ventanas se quedan donde las dejaste. El control es con
**tracking de manos** (índice + pulgar) y también con el dedo.

- **Realidad mixta**: passthrough de cámara con ARKit (6DoF, escala real en metros).
- **Hand tracking**: Vision `VNDetectHumanHandPoseRequest`, 21 puntos por mano,
  hasta 2 manos, dibujo del esqueleto en pantalla.
- **Ventanas**: video (HLS/MP4 o de tu galería) y navegador web real (`WKWebView`).
- **Gestos**: pinza sobre una ventana para agarrarla y moverla; dos manos para
  escalarla. Cada ventana también responde al dedo (arrastrar por la cabecera,
  pellizcar para escalar, ✕ para cerrar, 🔗 para cambiar la URL).

```
Pinza (índice + pulgar) sobre una ventana  →  la agarra
Mové la mano                               →  la arrastra por el mundo
Pinza con las dos manos y separalas        →  agranda
Pinza con las dos manos y juntalas         →  achica
```

---

## 1. Cómo obtener el `.ipa` (sin Mac)

Compilar para iOS necesita el SDK de Apple, que solo existe en macOS. La
solución es GitHub Actions: un runner macOS compila y publica el archivo.

1. Creá un repositorio en GitHub (puede ser privado) y subí **el contenido de
   esta carpeta** (no la carpeta en sí): `project.yml`, `MiXR/`, `Support/`,
   `.github/`.

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
5. Abrí la app y aceptá el permiso de cámara.

> **Caveat importante**: con Apple ID gratuito la app deja de abrirse a los
> 7 días. No es un bug: es el límite de Apple. Se renueva volviendo a firmar.
> Con cuenta de pago dura 1 año.

---

## 2. Uso

Al abrir, la app arranca ARKit y muestra la cámara. Abajo tenés la barra:

| Botón | Qué hace |
|---|---|
| **Video** | abre el stream de ejemplo de Apple en una ventana flotante |
| **Web** | abre `apple.com` en una ventana con navegador real |
| **Fotos** | elige un video de tu galería y lo abre en una ventana |
| **Manos** | prende/apaga el tracking (útil si te molesta el esqueleto) |
| **Limpiar** | cierra todas las ventanas |
| **🔗** (arriba a la derecha) | escribe una URL: si termina en `.m3u8`/`.mp4` abre video, si no, navegador |

Cada ventana tiene su cabecera: **🔗** cambia la URL y **✕** la cierra.
El enlace **funciona con audio**: el video suena por el altavoz del iPhone.

---

## 3. Cómo está hecho

```
project.yml                     proyecto XcodeGen (genera MiXR.xcodeproj)
Support/Info.plist              permisos (cámara, fotos, ATS), vertical
MiXR/
  App/MiXRApp.swift             entry point SwiftUI
  App/RootView.swift            barra de controles + estado
  App/XRCameraView.swift        puente SwiftUI ↔ UIKit
  Core/Config.swift             constantes (distancias, tamaños, límites)
  Core/XRSession.swift          orquesta ARKit + manos + ventanas + galería
  Hand/HandTracker.swift        Vision: 21 puntos → pantalla (con suavizado)
  Hand/HandOverlayView.swift    esqueleto dibujado con CAShapeLayer
  Hand/GestureEngine.swift      pinza → agarrar / escalar ventanas
  Windows/SpatialWindow.swift   modelo: tipo, posición 3D, ancho en metros
  Windows/WindowHostView.swift  proyección mundo→pantalla cada frame
  Windows/SpatialWindowView.swift  tarjeta de cristal + cabecera + gestos
  Windows/VideoContentView.swift   AVPlayerLayer
  Windows/WebContentView.swift     WKWebView
.github/workflows/build-ipa.yml  compila y publica el .ipa
```

### La idea matemática

Cada ventana guarda una posición **en metros** en el espacio de ARKit. En cada
frame se proyecta con `ARCamera.projectPoint` y se calcula cuántos puntos de
pantalla mide un metro a esa profundidad:

```
escala = (proyección vertical) * altoPantalla / 2 / profundidad
anchoEnPantalla = anchoFísico(metros) * escala
```

El resultado se aplica como `transform`, así la ventana se ve **más chica
cuanto más lejos** y se queda quieta en el aire cuando movés el teléfono
(paralaje real). Al arrastrarla con la mano, los puntos de pantalla se
convierten de vuelta a metros con esa misma escala.

---

## 4. Limitaciones honestas

- **Solo vertical**: la app está bloqueada en portrait. Es lo que permite que
  el mapeo de manos (Vision `.right`) sea exacto sin recalibrar.
- **Manos sin profundidad**: Vision devuelve 21 puntos 2D; el gesto de pinza se
  calcula por distancia normalizada al tamaño de la mano (la misma fórmula del
  port de MediaPipe de VRViewer). La profundidad de la mano no se usa, por eso
  agarrar funciona mejor de frente y con buena luz.
- **Sin oclusión**: las ventanas se dibujan siempre encima de la cámara; no hay
  malla del entorno, así que una ventana "detrás" de una mesa se sigue viendo.
  ARKit sin `planeDetection` no genera malla (ahorra batería). Se puede activar
  `sceneReconstruction` más adelante.
- **Hand tracking de Apple, no de visionOS**: en iOS no existe el hand tracking
  espacial de visionOS; esto es Vision sobre la cámara (funciona bien, pero no
  es lo mismo que un Vision Pro).
- **El primer arranque pide cámara** y ARKit tarda ~1 s en enganchar el mundo.
- **Batería**: cámara + ARKit + Vision a 24 Hz calienta el teléfono.

---

## 5. Problemas típicos

| Síntoma | Causa / solución |
|---|---|
| "Realidad mixta no disponible" | el iPhone es anterior al 6s o el permiso de cámara está denegado |
| Las manos no aparecen | poca luz, mano fuera de cuadro, o botón **Manos** apagado |
| El esqueleto va corrido | cámara trasera tapada parcialmente / funda que tapa el lente |
| Las ventanas tiemblan | ARKit perdiendo tracking: más luz y texturas en el piso |
| El video no carga | URL inválida o sin red; probá el stream de ejemplo |
| Se cae a los 7 días | firma gratuita de Apple: volvé a firmar con Sideloadly |
| Build rojo en Actions | mirá el artifact `xcodebuild-log` |

---

## 6. Compilar con Mac (alternativa)

```bash
brew install xcodegen
xcodegen generate
open MiXR.xcodeproj
```

Elegí tu equipo en *Signing & Capabilities*, conectá el iPhone y ejecutá.
El bundle id por defecto es `com.mixr.ios` (cambialo si te da conflicto).
