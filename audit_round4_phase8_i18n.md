# Auditoría Round 4 — Fase 8: i18n y accesibilidad

Fecha: 2026-05-11

---

## Estado del i18n

### Flutter app
- Idiomas: `es`, `en`, `fr`, `he` (Hebrew) ✓
- Implementación: clase `S` ([lib/core/l10n/s.dart](lib/core/l10n/s.dart)) con `_t(es, en, fr, he)` inline para cada string
- 1238 líneas con ~500+ strings traducidos
- **Sin archivos `.arb` o `intl`** — todo en código (custom solution)
- `MaterialApp.router` configurado con `S.supportedLocales` y delegate ✓
- RTL para Hebrew: Flutter maneja automáticamente cuando `Locale('he')` está activa + framework agrega `Directionality.rtl` al árbol — ✓

### Admin web
- Idiomas: **es, en, fr** ❌ — Hebrew NO soportado
- Implementación: TypeScript object literal en [src/lib/translations.ts](../../pushka_admin/src/lib/translations.ts)
- 3 locales de `date-fns`

---

## Bugs

### BUG-059 — Admin web sin soporte para Hebreo
- **Archivo**: [src/lib/translations.ts:4](../../pushka_admin/src/lib/translations.ts#L4)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: `type Lang = 'es' | 'en' | 'fr'`. Hebrew no está en la lista. Un tenant_admin israelí o argentino-religioso preferiría usar el admin en hebreo.
- **Impacto**: limita la usabilidad del panel admin a hispano/franco/anglo hablantes.
- **Fix propuesto**: agregar 'he' a `Lang` type, importar `he` locale de `date-fns`, agregar bloque de traducciones `he` al objeto `t`, y asegurar que el `LanguageContext` soporte RTL para HTML (`<html dir="rtl">` cuando lang = 'he').

### BUG-060 — "Jabad en Campus" y "Colel Chabad" hardcoded en `S` class
- **Archivo**: [lib/core/l10n/s.dart](lib/core/l10n/s.dart) líneas 458, 781, 791, 802, 803, 806, 818, 833, 1085, 1293
- **Severidad**: 🔴 **CRITICAL** (consolidado con BUG-001)
- **Descripción**: el modelo multi-tenant requiere que el branding del tenant aparezca en pantallas como About, Settings, share message, etc. Pero los strings de `S` están hardcodeados para Jabad en Campus:
  - `defaultPushkaName` → "Pushka Jabad en Campus" (esperaría: `${tenant.appName} Pushka`)
  - `colelJabad` → "Jabad en Campus"
  - `aboutTitle`, `aboutBreadcrumb` → "Jabad en Campus"
  - `aboutDescription` → texto referenciando a "Rabino Menachem Mendel Meer"
  - `shareMessage` → texto promocional con "Jabad en Campus"
  - `appDescription` → "La app de Tzedaká de Jabad en Campus"
  - `footerCopyright` → "© 2026 Jabad en Campus"
- **Impacto**: si un futuro tenant (otro Jabad, otra org caridad) instala la app, sus donantes verán "Jabad en Campus" en about, footer, share message — totalmente fuera de marca.
- **Fix propuesto**: separar los strings genéricos de los específicos del tenant. Los específicos deben venir de `TenantConfig` (appName, name, welcomeText, contactEmail) o de un campo nuevo `aboutText`/`footerText` editable desde admin. Refactor mayor pero necesario.

### BUG-061 — Share message hardcoded con nombre de tenant
- **Archivo**: [lib/core/l10n/s.dart:1293](lib/core/l10n/s.dart#L1293)
- **Severidad**: 🟠 **HIGH** (parte de BUG-060)
- **Descripción**: el texto que un user comparte al difundir la app incluye "Pushka de Tzedaká de Jabad en Campus" y un URL `https://pushkapp.cc/share` (también hardcoded).
- **Fix propuesto**: construir share message dinámicamente con `tenant.appName` + URL del tenant (slug).

### BUG-062 — Hardcode "Jabad en Campus" en settings_screen
- **Archivo**: [lib/features/settings/presentation/settings_screen.dart:538](lib/features/settings/presentation/settings_screen.dart#L538)
- **Severidad**: 🟡 **MEDIUM**

### BUG-063 — Hardcode "Jabad en Campus" en tenant_code_screen
- **Archivo**: [lib/features/tenant/presentation/tenant_code_screen.dart:172](lib/features/tenant/presentation/tenant_code_screen.dart#L172)
- **Severidad**: 🟡 **MEDIUM**

### BUG-064 — `support_screen.dart` hardcodea (ya reportado BUG-001/BUG-011)
- Crítico, ya documentado.

### BUG-065 — Falta diff sistemático de keys entre idiomas
- **Severidad**: 🟢 **LOW**
- **Descripción**: con `_t(es, en, fr, he)` cualquier dev podría agregar un getter nuevo con solo `_t('Texto')` (3 args opcionales). El compilador no fuerza traducciones — el inglés/francés/hebreo defaultean al español, lo que muestra ES en otros idiomas silenciosamente.
- **Fix propuesto** (opcional, mayor refactor): migrar a `flutter_localizations` + `.arb` files con `flutter gen-l10n`. Genera errores en build si falta una key.

### BUG-066 — Texto legal in-app (legal_content.dart) no se traduce dinámicamente al tenant
- **Severidad**: 🟠 **HIGH** (= BUG-002)
- Ya documentado.

---

## Accesibilidad (WCAG / a11y)

### `Semantics` widgets
Solo 2 archivos usan widgets de `Semantics` o `MergeSemantics`:
- `about_screen.dart`
- `app_drawer.dart`

#### BUG-067 — Cobertura mínima de Semantics labels
- **Severidad**: 🟢 **LOW**
- **Descripción**: la mayoría de widgets (botones, iconos) dependen de los labels automáticos de Material. Para screen readers (TalkBack/VoiceOver), esto es generalmente OK porque Material widgets ya tienen semantics. Pero widgets custom (Pushka 3D widget, 770 widget, jewish confetti) NO tienen semantics — un user con discapacidad visual no puede entender qué pasa.
- **Fix propuesto**: agregar `Semantics(label: ...)` a los widgets custom centrales (pushka, 770, donate button). Bajo costo de implementación, gran ganancia de accesibilidad.

### Tamaño de fuente / `MediaQuery.textScaleFactor`
- No verifiqué si los textos se escalan correctamente cuando el user agranda la fuente del sistema. **Necesita test manual** con accesibilidad del SO activada.

### Contrastes
- Brand colors (`primaryColor` default `#e8a87c` terracota) sobre blanco: contraste ratio ~3.5:1 ❌ — debajo del WCAG AA mínimo de 4.5:1
- En dark mode (sky blue sobre negro): contraste OK
- ⚠️ El primer tenant default no cumple WCAG AA para usuarios con visión reducida.

#### BUG-068 — Contraste de primaryColor default insuficiente
- **Severidad**: 🟢 **LOW**
- **Descripción**: terracota #e8a87c sobre fondo blanco no cumple WCAG AA.
- **Fix propuesto**: en lugar de usar primaryColor para texto, usar un color derivado más oscuro. O recomendar al tenant_admin que pruebe contraste con un widget de preview.

### RTL specific issues

Con `Locale('he')` activado, Flutter aplica `TextDirection.rtl` globalmente. **Cosas a verificar manualmente** (no se puede sin runtime):
- Iconos direccionales (flechas back, chevrons): ¿se voltean? Material widgets lo hacen automáticamente.
- Paddings asimétricos: ¿se voltean `EdgeInsets.only(left: X)`? Solo si usás `EdgeInsetsDirectional.only(start: X)`.
- Animaciones con `Transform.translate(Offset(x, 0))`: NO se voltean automáticamente. Pueden romper visualmente en HE.

#### BUG-069 — No verifiqué RTL en runtime
- **Severidad**: 🟡 **MEDIUM**
- **Fix propuesto**: test manual con device en Hebrew. Si hay glitches, reemplazar `EdgeInsets` por `EdgeInsetsDirectional`.

---

## Tabla resumen Fase 8

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-059 | 🟡 MEDIUM | Admin sin Hebrew | No (Pushka es ES/EN/FR mayoría) |
| BUG-060 | 🔴 CRITICAL | "Jabad en Campus" hardcoded en `S` | **Sí** para 2do tenant |
| BUG-061 | 🟠 HIGH | Share message hardcoded | **Sí** |
| BUG-062 | 🟡 MEDIUM | Hardcode en settings_screen | No (cosmético) |
| BUG-063 | 🟡 MEDIUM | Hardcode en tenant_code_screen | No |
| BUG-065 | 🟢 LOW | Sin diff de keys i18n | No |
| BUG-067 | 🟢 LOW | Semantics mínimo | No |
| BUG-068 | 🟢 LOW | Contraste primaryColor | No |
| BUG-069 | 🟡 MEDIUM | RTL no verificado en runtime | No |

**Resumen**: 1 CRITICAL, 1 HIGH, 4 MEDIUM, 3 LOW.

**Nota importante**: BUG-060 es el bloqueante real para escalar Pushka a múltiples tenants — el `S` class fue diseñado asumiendo que la app es solo de Jabad en Campus. Refactorizar a strings parametrizados con `tenant.appName/name` requiere tocar ~15-20 strings y revisar cada vista que los renderiza. Trabajo estimado: medio día.

---

Continúo a **Fase 9 — Tests**.
