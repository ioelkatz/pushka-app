# Plan Maestro — Pushka SaaS Multi-Tenant

**Filosofía:** Mejor hecho que rápido. Siempre a largo plazo. Seguridad y mejores prácticas ante todo.  
**Objetivo:** Una sola app Flutter white-label vendida como SaaS a 50-100 clientes (tenants), con comisión automática del 1-3% por transacción vía Stripe Connect.

---

## Roles del sistema

| Rol | Quién | Acceso |
|-----|-------|--------|
| `super_admin` | Solo Ioel | Todo — todos los tenants, métricas globales, crea/edita/suspende tenants, ajusta comisiones y precios por tenant |
| `tenant_admin` | El cliente (rabino, director) | Solo su organización — usuarios, donaciones, puede agregar colaboradores |
| `tenant_collaborator` | Asistente del cliente | Métricas de su org — solo lectura |
| Usuario final | El donante | Ve la app con branding de su tenant, no sabe que existe el resto |

---

## Estructura Firestore nueva

### `tenants/{tenantId}`
```
name: string                    // "Chabad México"
slug: string                    // "chabadmexico" — es el código Y el link
status: string                  // "active" | "grace_period" | "suspended" | "trial"

// Branding
primaryColor: string            // "#FF6B35"
secondaryColor: string          // "#FFD700"
logoUrl: string                 // Firebase Storage URL
appName: string                 // "Chabad Pushka México"
welcomeText: string             // Texto pantalla principal
showPoweredBy: boolean          // true → muestra "[TenantName] Pushka" en settings

// Localización
defaultLanguage: string         // "es" | "en" | "fr" | "he"
defaultCurrency: string         // "MXN"
defaultCountry: string          // "México"

// Legal / Contacto
contactEmail: string
contactPhone: string
privacyPolicyUrl: string
termsUrl: string
city: string
country: string

// Stripe Connect (dinero donantes → cuenta del cliente)
stripeConnectAccountId: string | null   // "acct_xxx"
stripeConnectStatus: string             // "not_connected" | "pending" | "active" | "restricted"
commissionRate: number                  // 0.03 (3%) — editable por super_admin por tenant

// Billing (cliente → paga a Ioel mensualmente)
planPrice: number                       // en USD — editable por super_admin por tenant
stripeSubscriptionId: string | null     // sub_xxx en el Stripe de Ioel
stripeCustomerId: string | null         // cus_xxx en el Stripe de Ioel (tarjeta del cliente)
paymentStatus: string                   // "current" | "grace_period" | "suspended"
billingCycleStart: timestamp
billingNextDue: timestamp
gracePeriodEndsAt: timestamp | null

// Admin del tenant
adminUid: string
adminEmail: string
createdAt: timestamp
updatedAt: timestamp
createdBy: string                       // uid del super_admin que lo creó
```

### Cambio en `users/{uid}`
```
tenantId: string    // nuevo campo — qué organización pertenece este usuario
```

### Custom Claims en Firebase Auth
```javascript
// super_admin
{ role: "super_admin" }

// tenant_admin
{ role: "tenant_admin", tenantId: "chabadmexico" }

// tenant_collaborator
{ role: "tenant_collaborator", tenantId: "chabadmexico" }
```

---

## FASE 1 — Backend y Base de Datos

### 1.1 [ ] Crear colección `tenants` en Firestore
- Definir schema completo
- Crear índices necesarios

### 1.2 [ ] Crear tenant piloto "Chabad México"
- Slug: "chabadmexico"
- Con datos reales del cliente actual
- Status: "active"

### 1.3 [ ] Migrar usuarios existentes
- Agregar `tenantId: "chabadmexico"` a todos los usuarios actuales
- Script de migración seguro (no destructivo)

### 1.4 [ ] Actualizar sistema de roles (Cloud Functions)
- Modificar `setAdminClaim()` para soportar role + tenantId
- Asignar `super_admin` a ioelkatz@gmail.com
- Asignar `tenant_admin` a jymmexico@gmail.com con tenantId: "chabadmexico"

### 1.5 [ ] Nueva Cloud Function: `createTenant`
- Solo super_admin puede llamarla
- Crea documento en `tenants/`
- Genera slug único
- Valida datos requeridos

### 1.6 [ ] Nueva Cloud Function: `updateTenant`
- Solo super_admin puede llamarla
- Actualiza branding, comisión, precio, status

### 1.7 [ ] Nueva Cloud Function: `getTenantBySlug`
- Pública (para la app cuando el usuario entra un código)
- Devuelve config de branding (NO datos sensibles como Stripe keys)

### 1.8 [ ] Nueva Cloud Function: `getTenantConfig`
- Autenticada (para usuarios ya registrados)
- Devuelve configuración completa de branding del tenant del usuario

### 1.9 [ ] Modificar `createPaymentIntent` para Stripe Connect
- Agregar `application_fee_amount: amountCents * tenant.commissionRate`
- Agregar `transfer_data: { destination: tenant.stripeConnectAccountId }`
- Leer tenantId del usuario que llama
- Leer commissionRate del tenant
- Fallback seguro si tenant no tiene Stripe Connect activo

### 1.10 [ ] Nueva Cloud Function: `createStripeConnectLink`
- Solo super_admin o tenant_admin pueden llamarla
- Genera URL de OAuth de Stripe Connect para que el cliente conecte su cuenta
- Guarda state para verificar el callback

### 1.11 [ ] Nueva Cloud Function: `handleStripeConnectOAuth`
- Endpoint HTTP (no callable) — recibe el callback de Stripe OAuth
- Intercambia code por access_token y stripe_user_id
- Guarda stripeConnectAccountId en tenants/{tenantId}
- Actualiza stripeConnectStatus a "active"

### 1.12 [ ] Actualizar `stripeWebhook`
- Manejar eventos de cuentas Connect (transfers, payouts)
- Registrar correctamente el tenantId en los eventos

### 1.13 [ ] Actualizar Firestore Security Rules
- usuarios solo leen/escriben su propio doc (ya existe)
- tenant_admin solo puede leer usuarios de su tenantId
- tenant_admin solo puede leer transacciones de su tenantId
- super_admin puede leer/escribir todo
- `tenants/` solo readable por super_admin y el tenant_admin correspondiente
- campos sensibles de tenants (Stripe keys) solo super_admin

### 1.14 [ ] Actualizar funciones admin existentes para tenant context
- `getAdminStats()` → filtrar por tenantId si es tenant_admin
- `getRecentTransactions()` → filtrar por tenantId
- `getFailedPayments()` → filtrar por tenantId
- `setUserBlocked()` → verificar que el usuario pertenece al tenant del caller

---

## FASE 2 — Flutter App

### 2.1 [ ] Modelo y repositorio de tenant config
- Clase `TenantConfig` en Dart
- `TenantRepository` con stream de config
- Cache local en Hive para branding (carga rápida en cold start)

### 2.2 [ ] Tema dinámico por tenant
- Cargar primaryColor, secondaryColor del tenant al iniciar sesión
- Generar `ThemeData` dinámicamente (reemplaza el hardcoded)
- Logo dinámico desde Firebase Storage URL
- Aplicar en toda la app sin reiniciar

### 2.3 [ ] Pantalla de asignación de tenant
- Si el usuario no tiene tenantId → mostrar pantalla para ingresar código
- Validar slug contra `getTenantBySlug()`
- Mostrar preview del branding del tenant antes de confirmar
- Guardar tenantId en el perfil al registrarse

### 2.4 [ ] Deep linking
- Configurar `pushka.app/join/{slug}` en Android e iOS
- Al abrir el link → pre-llenar el código de tenant en la pantalla de registro
- Si ya está logueado → mostrar pantalla de "querés unirte a [Org]?"

### 2.5 [ ] Actualizar flujo de registro
- Después de crear cuenta → asignar tenantId
- Crear usuario con tenantId desde el inicio
- Language por defecto = tenant.defaultLanguage
- Currency por defecto = tenant.defaultCurrency

### 2.6 [ ] Splash screen y branding
- Mostrar logo del tenant en el splash
- Nombre de la app del tenant en el header
- "Powered by [TenantName] Pushka" en pantalla de Settings (pequeño, gris)

### 2.7 [ ] Texto dinámico
- welcomeText del tenant en la pantalla principal
- Nombre de la organización donde corresponda

### 2.8 [ ] Activar Google Pay
- Agregar `googlePay: PaymentSheetGooglePay(merchantCountryCode: ..., currencyCode: ...)` en initPaymentSheet
- merchantCountryCode dinámico según el tenant

### 2.9 [ ] Activar Apple Pay
- Configurar merchant ID en Xcode (requiere CI/CD o acceso Mac)
- Agregar Apple Pay a `initPaymentSheet`

---

## FASE 3 — Admin Web (pushka_admin)

### 3.1 [ ] Actualizar AuthContext para nuevos roles
- Leer custom claims: role + tenantId
- Rutas protegidas por rol
- Super admin ve todo, tenant_admin ve solo su tenant

### 3.2 [ ] Nueva página: Tenants (super_admin only)
- Lista de todos los tenants con:
  - Nombre, ciudad, status, Stripe Connect status
  - Total donaciones del mes (en USD)
  - Comisión generada para Ioel
  - Fecha de vencimiento de billing
  - Botón para ver detalle

### 3.3 [ ] Nueva página: Tenant Detail (super_admin only)
- Config completa del tenant
- Editor de comisión (commissionRate)
- Editor de precio mensual (planPrice)
- Estado de Stripe Connect + botón para regenerar link OAuth
- Estado de billing + historial de pagos
- Lista de usuarios del tenant
- Botones: suspender / activar / eliminar tenant

### 3.4 [ ] Nueva página / flujo: Onboarding de Tenant (super_admin only)
Formulario en pasos:
- Paso 1: Datos básicos (nombre, ciudad, país, email, teléfono)
- Paso 2: Branding (upload logo, color primario, nombre de app, texto de bienvenida)
- Paso 3: Localización (idioma default, moneda default)
- Paso 4: Textos legales (política de privacidad URL, términos URL)
- Paso 5: Stripe Connect (botón → abre OAuth de Stripe)
- Paso 6: Billing (precio mensual, crear suscripción Stripe)
- Paso 7: Resumen + generar link de invitación

### 3.5 [ ] Filtrar Dashboard por tenantId
- Super admin: dropdown para ver global o por tenant específico
- Tenant admin: ve solo su tenant automáticamente

### 3.6 [ ] Filtrar CRM por tenantId
- Super admin: ve todos los usuarios con columna de tenant
- Tenant admin: ve solo sus usuarios

### 3.7 [ ] Filtrar Transacciones por tenantId
- Super admin: ve todas con columna de tenant
- Tenant admin: ve solo las suyas

### 3.8 [ ] Nueva página: Mi Organización (tenant_admin)
- Ver config de su organización (solo lectura para campos sensibles)
- Editar: logo, colores, textos (si habilitamos self-service)
- Ver estado de Stripe Connect
- Ver estado de billing y próximo vencimiento
- Link de invitación propio para compartir

### 3.9 [ ] Gestión de colaboradores (tenant_admin)
- Agregar colaborador por email
- Asignar rol tenant_collaborator
- Revocar acceso

### 3.10 [ ] Métricas de comisiones para super_admin
- Total comisiones generadas por período
- Desglose por tenant
- Gráfico de tendencia

---

## FASE 4 — Billing y Automatización

### 4.1 [ ] Stripe Billing: suscripciones para tenants
- Crear producto/precio en el Stripe de Ioel
- Cloud Function: `createTenantSubscription(tenantId, planPrice)`
- Guarda stripeSubscriptionId y stripeCustomerId en tenant doc

### 4.2 [ ] Webhook de Stripe Billing
- Manejar `invoice.payment_succeeded` → renovar billing
- Manejar `invoice.payment_failed` → iniciar periodo de gracia

### 4.3 [ ] Sistema de periodo de gracia
- Al detectar fallo de pago → poner tenant en "grace_period"
- Calcular gracePeriodEndsAt = ahora + 30 días
- Cloud Function scheduled (diaria): verificar tenants en grace_period

### 4.4 [ ] Emails automáticos de advertencia al tenant
- 30 días antes del vencimiento: "Tu suscripción vence en 30 días"
- 20, 10, 5 días: recordatorios escalados
- Día 0: "Tu servicio fue suspendido"
- Sistema: Firebase Extensions (Trigger Email) o SendGrid

### 4.5 [ ] Email de alerta a super_admin
- Cuando un tenant entra en grace_period → email a ioelkatz@gmail.com
- Para dar seguimiento manual

### 4.6 [ ] Banner de advertencia en admin web del tenant
- Si paymentStatus = "grace_period" → banner rojo con días restantes
- Visible solo para tenant_admin, no para colaboradores ni usuarios finales

### 4.7 [ ] Suspensión automática
- Al expirar grace_period → status = "suspended"
- App: usuarios del tenant ven pantalla de "Servicio temporalmente no disponible"
- Admin web del tenant: acceso reducido, solo billing

---

## FASE 5 — Lanzamiento

### 5.1 [ ] Limpieza de datos de prueba (antes de publicar)
- Borrar todos los usuarios de prueba
- Borrar todas las transacciones de prueba
- Resetear métricas
- Dejar el sistema vacío y limpio

### 5.2 [ ] Auditoría de seguridad
- Revisar todas las Cloud Functions: validaciones, autenticación, rate limiting
- Revisar Firestore rules: ningún dato sensible accesible sin auth
- Revisar que Stripe keys nunca se exponen al cliente Flutter
- Revisar que commissionRate no sea modificable por el tenant

### 5.3 [ ] CI/CD para iOS (GitHub Actions o Codemagic)
- Build automático de iOS sin necesitar Mac local
- Firma con certificados del Apple Developer

### 5.4 [ ] Publicar en Play Store
- Preparar listing: screenshots, descripción, icono
- Internal testing → closed testing → production

### 5.5 [ ] Publicar en App Store
- Preparar listing
- Review de Apple (puede tomar 1-7 días)

### 5.6 [ ] Monitoring post-lanzamiento
- Alertas en Firebase cuando hay errores en Cloud Functions
- Dashboard de salud del sistema para super_admin

---

## Estado actual del progreso

- [x] App Flutter funcional (4 idiomas, Stripe básico, Firebase auth)
- [x] Admin web con métricas, CRM, transacciones
- [x] Cloud Functions: pagos, wallet, notificaciones, rate limiting
- [x] SHA-1 y SHA-256 registrados en Firebase para release
- [x] Stripe Secret Key deployada en Firebase
- [x] flutter_stripe actualizado a 12.6.0
- [ ] FASE 1: Backend multi-tenant
- [ ] FASE 2: App dinámica por tenant
- [ ] FASE 3: Admin web multi-tenant
- [ ] FASE 4: Billing automatizado
- [ ] FASE 5: Lanzamiento

---

## Decisiones pendientes

- [ ] ¿Qué ve un usuario que descarga la app sin link ni código? (decidir antes de Fase 2.3)
- [ ] Nombre final de la app en las stores (por ahora: "Chabad Pushka")
- [ ] ¿Self-service de branding para tenant_admin o solo Ioel edita? (recomendación: Ioel edita en onboarding, tenant puede cambiar logo/colores después)

---

## Notas técnicas importantes

- **Seguridad Stripe:** Las Stripe Secret Keys NUNCA llegan al cliente Flutter. Solo viven en Cloud Functions como secrets de Firebase.
- **Stripe Connect:** El `stripeConnectAccountId` (acct_xxx) es la única referencia guardada. Las keys del cliente nunca se guardan en Firestore.
- **Firestore rules:** El tenantId en el custom claim es la fuente de verdad para autorización, no el campo en Firestore (que podría ser manipulado).
- **Migración:** Siempre no-destructiva. Agregar campos sin borrar los existentes.
- **Datos de prueba:** Serán borrados en Fase 5.1 antes de publicar.
