# FreshBox SpA - EP3 ARY1102 (arquitectura hibrida EKS + serverless)

Infraestructura como codigo (AWS CLI + kubectl + helm) para AWS Academy Learner Lab (us-east-1, LabRole).
Cada script es idempotente y guarda los IDs en `state.env` (no se versiona). Las credenciales de BD se generan en `.secrets.env` (no se versiona).

## Fase A - Base (equivale al EP2)
| Script | Que hace | Tiempo aprox. |
|---|---|---|
| `00-preflight.sh` | Herramientas, cuenta, LabRole | 1 min |
| `01-network.sh` | VPC /22, 6 subredes, IGW, NAT, rutas, 4 SG | 3-5 min |
| `02-rds.sh` | Inicia RDS MySQL Multi-AZ cifrado (no espera) | 1 min |
| `03-eks.sh` | Cluster + Node Group t4g.small (EBS cifrado) | 15 min |
| `04-addons.sh` | metrics-server, CloudWatch Observability, LB Controller, Cluster Autoscaler | 5 min |
| `05-db-init.sh` | Espera RDS, carga productos + ordenes, crea usuario de app (Job en el cluster) | 5-10 min |
| `verify-base.sh` | Verificacion integral -> TODO OK | 1 min |

`nodes.sh pause|resume` baja/sube los nodos entre sesiones.

## Fase B - EP3 (siguiente entrega)
ECR + pods EKS (Ingress por metodo HTTP), DynamoDB + SQS + VPC Endpoint, 3 Lambdas, API Gateway, S3, verify-ep3.

## Fase B (EP3): EKS + serverless
Ejecutar en orden (cada uno con `2>&1 | tee logs/NN.log`):
06-images.sh (ECR arm64) · 07-eks-apps.sh (4 pods + Ingress por metodo HTTP) · 08-data.sh (DynamoDB TTL, SQS+DLQ, VPC Endpoint) ·
09-lambdas.sh (Cart, Create-Order, Process-Order + trigger SQS) · 10-apigw.sh (API REST, CORS, stage prod) · 11-frontend.sh (S3) ·
verify.sh (end-to-end) · loadtest.sh (HPA, concurrencia y cold start).
Cambios respecto del paquete del docente: Node 20, carrito acumulativo (ADD), Process-Order idempotente (order_id UNIQUE) con fallos parciales,
GET /api/orders/{id} para confirmar "Su pedido fue procesado", frontend sin innerHTML y con manejo de errores.
