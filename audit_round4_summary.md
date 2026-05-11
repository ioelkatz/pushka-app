# Auditoría Round 4 — Síntesis ejecutiva

Fecha: 2026-05-11
Branch: `dev`
Cobertura: 10 fases, ~70 bugs catalogados, ~3000+ líneas de reporte

---

## Resumen ejecutivo

**Estado de Pushka pre-launch (escala 1-10): 6.5/10**

La plataforma tiene una **arquitectura sólida** (Firestore rules granulares, Stripe webhook bien diseñado, multi-tenant correcto). Pero hay **4 bugs CRITICAL bloqueantes** antes de invitar usuarios reales más allá de Jabad en Campus, y dos de ellos comprometen el modelo de negocio mismo.

### Lo que está sólido ✅
- Firestore rules con `affectedKeys()` defensivo en cada update
- Stripe webhook con signature + idempotency + drift detection + out-of-order guards
- Custom claims con uso correcto de `setCustomUserClaims` (replace, preservación explícita de campos)
- Rate limiting en 33 CFs
- App Check enforced en CFs user-facing
- deleteAccount + deleteTenant con sweep paginado
- Bootstrap super_admin con side-door automático
- Atomic slug uniqueness via `_tenantSlugs` lock + transaction
- Correlation ID end-to-end (cliente → CF → Stripe → webhook → Firestore)
- Lazy migration legacy → multi-tenant
- Orphan healing automático en `getTenantConfig`

### Lo que está roto 🔴
- Soporte y textos legales hardcodeados → **app no es realmente multi-tenant** (Jabad en Campus es el único tenant viable HOY)
- `createTenantSubscription` nunca se llama → **Pushka no factura mensualidad a ningún cliente**
- Donaciones a tenant sin Connect activo van al Stripe principal → **el rab no recibe nada hasta completar Connect**
- Case-sensitivity en `setAdminClaim` permite revocar super_admin → **DoS al super_admin**

---

## Tabla consolidada de bugs por severidad

### 🔴 CRITICAL — bloqueantes inmediatos

| ID | Fase | Título | Archivo | Estimado fix |
|---|---|---|---|---|
| BUG-001 / BUG-011 | 1 / 2 | `support_screen.dart` hardcodea email `jymmexico@gmail.com` + branding Colel Chabad | [lib/features/support/presentation/support_screen.dart:99](lib/features/support/presentation/support_screen.dart#L99) | 2-3h |
| BUG-016 / BUG-026 | 2 / 4 | `createTenantSubscription` no se llama desde ningún lado → Pushka no factura | [functions/index.js:6944](functions/index.js#L6944) | 3-4h |
| BUG-018 / BUG-014 | 2 / 3 | Donaciones a tenant sin Connect activo caen al Stripe principal | [functions/index.js:685-689](functions/index.js#L685) | 30min |
| BUG-035 | 5 | `setAdminClaim` permite revocar super_admin via uppercase email | [functions/index.js:4470](functions/index.js#L4470) | 5min |
| BUG-060 | 8 | `S` class hardcodea "Jabad en Campus"/"Colel Chabad" en ~15 strings → no escala a otros tenants | [lib/core/l10n/s.dart](lib/core/l10n/s.dart) líneas 458, 781, 791, 802, 803, 806, 818, 833, 1085, 1293 | 4-6h |

### 🟠 HIGH — antes de escalar

| ID | Fase | Título | Bloquea? |
|---|---|---|---|
| BUG-002 / BUG-012 / BUG-066 | 1 / 2 / 8 | `legal_content.dart` hardcodea `support@pushkaapp.com` en 4 idiomas | Multi-tenant |
| BUG-010 | 2 | Cambio `adminEmail` no transfiere claims al nuevo admin | Op multi-tenant |
| BUG-017 / BUG-027 | 2 / 4 | Cambiar `planPrice` no actualiza Stripe Subscription | Billing fantasma |
| BUG-019 | 3 | OAuth Connect marca `active` sin verificar `charges_enabled` | Tests |
| BUG-023 | 3 | `account.updated` → restricted no alerta super_admin | Operacional |
| BUG-028 | 4 | `subscriptionMonthlyAmount` campo fantasma (vs `planPrice`) | Reportes |
| BUG-034 | 4 | Sin billing portal Stripe para tenant_admin (self-service) | Escala >1 tenant |
| BUG-045 | 6 | No hay compresión de foto perfil → uploads >5MB fallan | UX |
| BUG-051 | 6 | Sin backups Firestore en producción | Riesgo operacional |
| BUG-056 | 7 | `useUsers` admin sin paginación → carga toda la tabla | A >500 users |
| BUG-061 | 8 | Share message hardcoded "Jabad en Campus" | Multi-tenant |

### 🟡 MEDIUM (10) y 🟢 LOW (12)

Detalle en cada reporte de fase. Resumen:
- 10 MEDIUM: cleanup, sync minor gaps, observability, performance
- 12 LOW: refinamientos, edge cases, mejoras de UX

---

## Plan de remediación ordenado

### Sprint 1 — Pre-launch Jabad en Campus (1-2 días)

Mínimo para invitar al rab + arrancar prueba real:

1. **BUG-035** (5 min): fix case-sensitivity en `setAdminClaim` línea 4470
2. **BUG-018** (30 min): rechazar `createPaymentIntent` cuando `stripeConnectAccountId` es null
3. **BUG-026** (3-4h): activar el flujo de `createTenantSubscription` — agregar botón en `TenantDetailPage` o encadenar a `createTenant`
4. **BUG-001** (2-3h): refactor de `support_screen.dart` para leer `contactEmail` del tenant + branding dinámico

**Total Sprint 1**: ~7 horas dev. Deploy a prod.

### Sprint 2 — Operacional (2-3 días)

5. **BUG-002/066** (3h): `legal_content.dart` lee `tenant.contactEmail` (fallback a Pushka). Decidir si `privacyPolicyUrl`/`termsUrl` del tenant abren WebView externa o usan el contenido in-app
6. **BUG-027** (2h): cuando super_admin cambia `planPrice`, hacer `stripe.subscriptions.update` con proration
7. **BUG-010** (2h): cuando super_admin cambia `adminEmail`, también aplicar/revocar claims
8. **BUG-019** (1h): verificar `charges_enabled` en `handleStripeConnectOAuth`
9. **BUG-023** (1h): alerta super_admin cuando Connect pasa a `restricted`
10. **BUG-045** (2h): compresión de foto perfil pre-upload

**Total Sprint 2**: ~11 horas dev.

### Sprint 3 — Multi-tenant ready (3-5 días)

11. **BUG-060** (4-6h): refactor `S` class — extraer "Jabad en Campus" / "Colel Chabad" a parámetros del tenant
12. **BUG-061** (1h): share message dinámico con `tenant.appName`
13. **BUG-034** (3h): CF `createBillingPortalSession` + botón en `MyOrganizationPage`
14. **BUG-051** (2h): scheduled Firestore exports + bucket GCS con lifecycle
15. **BUG-028** (1h): decidir `subscriptionMonthlyAmount` vs `planPrice` (uno o ambos, documentar)
16. **BUG-056** (3-4h): paginación + búsqueda server-side para `useUsers`

**Total Sprint 3**: ~14-18 horas dev.

### Sprint 4 — Tests + clean-up (1-2 semanas)

17. Implementar Plan Fase 9: ~900 tests
18. Backfill `tenantId` en transactions legacy (BUG-048)
19. Resolver MEDIUMs y LOWs restantes

---

## Riesgos identificados

### Riesgo 1: Donante manda dinero al Stripe principal (Ioel)
**Probabilidad**: alta si BUG-018 no se arregla antes del launch.
**Mitigación**: arreglar BUG-018 Sprint 1.

### Riesgo 2: Pushka no factura su SaaS
**Probabilidad**: 100% hoy (BUG-026).
**Mitigación**: arreglar BUG-026 Sprint 1 o usar el workaround manual de Cloud Shell que documenté.

### Riesgo 3: Pérdida de datos por falta de backups
**Probabilidad**: baja (Firestore es muy estable) pero impacto alto.
**Mitigación**: activar exports automáticos Sprint 2-3.

### Riesgo 4: DoS al super_admin
**Probabilidad**: extremadamente baja (atacante tendría que ser tenant_admin first admin).
**Mitigación**: BUG-035 fix de 5 minutos.

### Riesgo 5: Otros tenants ven branding de Jabad en Campus
**Probabilidad**: cierta cuando se agregue tenant #2.
**Mitigación**: Sprint 3 (refactor `S` class).

---

## Métricas de la auditoría

- **Fases ejecutadas**: 10
- **Archivos generados**: 12 markdown + 2 esqueletos test
- **Bugs catalogados**: ~70 (entre fases puede haber duplicados consolidados)
- **CRITICAL**: 5
- **HIGH**: 13
- **MEDIUM**: ~17
- **LOW**: ~25
- **Líneas de código Cloud Functions revisadas**: ~7500
- **Reglas Firestore revisadas**: ~615 líneas
- **CFs auditadas**: 52
- **Páginas admin web revisadas**: 14
- **Pantallas Flutter mapeadas**: ~25

---

## Archivos generados

En la raíz de `c:/dev/pushka_app/`:

1. [audit_round4_phase0_map.md](audit_round4_phase0_map.md) — Mapeo
2. [audit_round4_phase1_admin_cleanup.md](audit_round4_phase1_admin_cleanup.md) — Limpieza admin
3. [audit_round4_phase2_sync.md](audit_round4_phase2_sync.md) — Sync admin↔app
4. [audit_round4_phase3_stripe_connect.md](audit_round4_phase3_stripe_connect.md) — Stripe Connect
5. [audit_round4_phase4_subscriptions.md](audit_round4_phase4_subscriptions.md) — Suscripción SaaS
6. [audit_round4_phase5_security.md](audit_round4_phase5_security.md) — Seguridad
7. [audit_round4_phase6_persistence.md](audit_round4_phase6_persistence.md) — Persistencia
8. [audit_round4_phase7_performance.md](audit_round4_phase7_performance.md) — Performance
9. [audit_round4_phase8_i18n.md](audit_round4_phase8_i18n.md) — i18n
10. [audit_round4_phase9_tests.md](audit_round4_phase9_tests.md) — Tests plan
11. [audit_round4_summary.md](audit_round4_summary.md) — Este documento
12. [functions/test/README.md](functions/test/README.md) — Tests setup
13. [functions/test/createPaymentIntent.test.js](functions/test/createPaymentIntent.test.js) — Esqueleto ejemplo

---

## Recomendación final

**No invitar a Jabad en Campus a producción hoy.** Antes:

1. ✅ Ejecutar **Sprint 1** (7 horas dev) — los 4 CRITICAL bloqueantes
2. ✅ Probar pago real $1 USD en `flavor prod` con tarjeta real (validar end-to-end)
3. ✅ Coordinar Stripe Connect onboarding con el rab (este es el bottleneck externo)
4. ✅ Confirmar que `createTenantSubscription` se ejecutó para Jabad en Campus
5. ✅ Activar exports Firestore (Sprint 3 BUG-051 ahora si es posible)

Después, Sprint 2 puede correr en paralelo a las primeras donaciones reales.

Sprint 3 (multi-tenant prep) puede esperar hasta que esté listo el segundo tenant.

---

**Audit completado**. Esperando luz verde de Ioel para empezar fixes.
