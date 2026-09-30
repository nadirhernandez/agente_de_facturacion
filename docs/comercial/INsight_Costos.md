# INsight — Estructura de costos y precios sugeridos

Fecha de referencia: septiembre 2026. Precios de AWS en US$ según lista pública de
[Amazon Quick Sight](https://aws.amazon.com/quicksight/pricing/) para us-east-1. Los demás servicios
son estimaciones sobre el consumo observado en el piloto (1.1 M de facturas, 2.4 M de líneas).

---

## 1. Costo de AWS por cliente (lo que paga INFILE)

Cada cliente vive en su propia cuenta de AWS. El costo tiene una parte **fija** (independiente
del volumen) y una **variable** (por usuario y por datos).

### Fijo por cuenta

| Concepto | US$ / mes | Nota |
|---|---|---|
| Cargo de infraestructura Quick (Q&A, Topics, usuarios Pro) | 250.00 | Obligatorio si hay chat |
| Pipeline (Glue, Lambda, EventBridge, SNS, KMS, CloudWatch) | 15–40 | Depende de frecuencia de carga |
| App (CloudFront, API Gateway, Cognito ≤ 50 usuarios, WAF) | 8–15 | WAF ~US$ 6 fijos |
| Athena (consultas del pipeline y del chat) | 5–20 | US$ 5 por TB escaneado; Iceberg particionado |
| S3 (raw + Iceberg + resultados) | 1–5 | ~US$ 0.023 / GB |
| **Subtotal fijo** | **≈ 280–330** | |

### Variable

| Concepto | US$ | Nota |
|---|---|---|
| Usuario **Reader Pro** (chat + tablero) | 20.00 / usuario / mes | Mínimo para el chat |
| Usuario **Reader** (solo tablero, sin chat) | 3.00 / usuario / mes | Opción económica |
| Usuario **Author Pro** (administrador de tableros) | 40.00 / usuario / mes | 1 por cliente, opcional |
| SPICE (copia en memoria de los datos) | 0.38 / GB / mes | 1 M facturas ≈ 0.5 GB |
| Cognito | 0.0055 / usuario activo / mes | Gratis hasta 50 MAU; despreciable |

### Costo total estimado por tamaño de cliente

| Perfil | Facturas / mes | Usuarios | AWS US$ / mes |
|---|---|---|---|
| Pequeño | hasta 5,000 | 3 Reader Pro | ≈ 350 |
| Mediano | hasta 50,000 | 5 Reader Pro + 1 Author Pro | ≈ 440 |
| Grande | hasta 500,000 | 10 Reader Pro + 1 Author Pro | ≈ 560 |
| Corporativo | > 500,000 | 25 Reader Pro + 2 Author Pro | ≈ 900 |

> El cargo fijo de US$ 250 es el componente que más pesa en clientes pequeños. Es el número que
> decide si el chat va en todos los planes o solo en los superiores.

---

## 2. Precio sugerido al cliente final

Suscripción mensual, usuarios incluidos, sin costo de implementación (los datos ya están en INFILE).

| Plan | Incluye | Precio US$ / mes | Precio Q / mes* | Margen bruto aprox. |
|---|---|---|---|---|
| **Esencial** | Tablero + chat, 3 usuarios, hasta 5,000 facturas/mes | 599 | Q 4,650 | ~40 % |
| **Profesional** | Tablero + chat + alertas, 5 usuarios, hasta 50,000 facturas/mes | 999 | Q 7,750 | ~55 % |
| **Empresarial** | Todo lo anterior, 10 usuarios, hasta 500,000 facturas/mes, dominio propio | 1,799 | Q 13,950 | ~68 % |
| **Corporativo** | 25 usuarios, volumen ilimitado, soporte prioritario, fuentes adicionales | 2,999 | Q 23,250 | ~70 % |
| Usuario adicional | Reader Pro | 35 | Q 270 | ~43 % |
| Usuario solo tablero | Reader (sin chat) | 8 | Q 62 | ~62 % |

\* Tipo de cambio de referencia Q 7.75 / US$; ajustar al vigente.

### Lectura rápida

- El plan **Esencial** cubre el costo fijo de AWS con margen modesto; su función es la entrada.
- A partir de **Profesional** el margen supera el 50 % porque el costo fijo se diluye.
- El **usuario adicional** a US$ 35 sobre un costo de US$ 20 deja margen para soporte.

---

## 3. Costos que no están en AWS

| Concepto | Estimación | Nota |
|---|---|---|
| Soporte nivel 1 (por cliente) | 1–2 h / mes | Onboarding, preguntas sobre el chat |
| Operación de plataforma (todos los clientes) | 0.25 FTE hasta 20 clientes | Despliegues, monitoreo, alertas |
| Certificado y dominio propio (plan Empresarial+) | US$ 0 (ACM) + dominio del cliente | |
| Personalización de marca en login | 1–2 h por cliente | Una vez |

---

## 4. Supuestos y riesgos del cálculo

1. **Cargo fijo de Quick.** US$ 250 / cuenta / mes es el precio publicado. Con consolidación de
   facturación vía IAM Identity Center, AWS permite agrupar Reader Pro / Author Pro entre cuentas
   del mismo pagador, pero el cargo fijo de infraestructura se cobra por cuenta que use Q&A.
   Confirmar con el equipo de cuenta de AWS si aplica un esquema por volumen de cuentas.
2. **Promoción vigente.** Hasta el 31 de diciembre de 2026, los Author de Quick Sight tienen acceso
   promocional a capacidades de Quick Enterprise. No contar con ello para el precio.
3. **Athena.** El costo crece con el número de preguntas al chat. Con Iceberg particionado y
   SPICE, la mayoría de las consultas del usuario no tocan Athena; las del pipeline sí.
4. **SPICE.** Un cliente con 10 M de facturas/año necesitaría ~5 GB (US$ 2 / mes): despreciable.
5. **Glue.** El piloto usa 2 workers G.1X. Clientes con millones de facturas/mes requieren más
   workers; el costo sube linealmente pero sigue siendo marginal frente al cargo fijo de Quick.
6. **Cognito.** Gratis hasta 50 usuarios activos al mes por cuenta; los planes propuestos no lo
   superan.

---

## 5. Punto de equilibrio

Con el costo de operación de plataforma (0.25 FTE ≈ US$ 1,500 / mes) y un mix de 60 % Esencial,
30 % Profesional, 10 % Empresarial:

| Clientes | Ingreso US$ / mes | Costo AWS + operación | Margen |
|---|---|---|---|
| 5 | 4,300 | 3,550 | 17 % |
| 10 | 8,600 | 5,600 | 35 % |
| 20 | 17,200 | 9,700 | 44 % |
| 50 | 43,000 | 22,000 | 49 % |

El negocio se vuelve interesante a partir de **10 clientes**, y el margen se estabiliza cerca del
50 % con 50. La palanca principal es mover clientes de Esencial a Profesional.
