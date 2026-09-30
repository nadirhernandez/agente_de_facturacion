# INsight by INFILE

**Analítica conversacional sobre la facturación electrónica que ya administramos.**

---

## La oportunidad

INFILE es el repositorio de facturación electrónica de miles de contribuyentes. Ese activo hoy
cumple una función regulatoria. La misma información, puesta a trabajar para el cliente, es la
base de un producto analítico que ningún competidor puede ofrecer con la misma fricción: **nosotros
ya tenemos los datos**.

## Qué es

Una plataforma donde el cliente **le pregunta a sus propias ventas en lenguaje natural** y obtiene
respuestas inmediatas con gráficas, sobre sus documentos reales, actualizados con cada emisión.

> "¿Cuánto facturé el mes pasado frente al anterior?"
> "¿Qué regiones lideran y cuáles caen?"
> "¿Quiénes son mis cinco mejores clientes este trimestre?"

Incluye un tablero de indicadores siempre al día (facturación, unidades, ticket promedio,
tendencia, comparativos por región, canal, categoría y producto), alertas automáticas de caída de
ventas y soporte multimoneda (GTQ y USD, nunca mezclados).

## Cómo funciona

Ensambla capacidades que ya tenemos, sin construir desde cero:

```
Facturas electrónicas (INFILE)  →  Modelo analítico (AWS)  →  Amazon Quick  →  App INsight
```

Amazon Quick es el motor de inteligencia analítica y conversacional de AWS. Cualquier empresa
puede usarlo, pero tiene que traer, integrar y mantener sus datos. INsight elimina ese paso:
el cliente no instala nada, no integra nada, no exporta nada.

## Por qué INFILE

| Ventaja | Qué significa |
|---|---|
| Los datos ya están con nosotros | Cero fricción de adopción para el cliente |
| Infraestructura AWS activa | Costo marginal bajo por cliente adicional |
| Relación directa con el contribuyente | Canal comercial existente |
| Una cuenta AWS por cliente | Aislamiento total; un cliente nunca ve a otro |

## Estado actual

- Prototipo **funcional y desplegado**, con datos sintéticos representativos (1.1 M de facturas).
- Autenticación corporativa, tablero, chat analítico, alertas y modelo multimoneda operando.
- Acceso de demostración disponible sin registro (link de invitado).
- Arquitectura reproducible por cliente definida; falta aplicarla en una primera cuenta real.

## Modelo de negocio (propuesta)

Suscripción mensual por empresa con usuarios incluidos, escalonada por volumen de facturación y
número de usuarios. Detalle en `INsight_Costos.md`. Costo base de plataforma por cliente:
~US$ 300–400 / mes; precio sugerido desde US$ 599 / mes.

## Siguiente paso

Validar viabilidad comercial con 3 a 5 clientes piloto durante un trimestre y, en paralelo,
completar la automatización del despliegue por cliente para poder escalar sin fricción operativa.

---

*Contacto: René Hernández · INFILE · Demo: solicitar link de invitado*
