// FreshBox - Lambda Create-Order (EP3). POST /api/orders: carrito -> total -> SQS. GET /api/orders/{orderId}: estado.
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, QueryCommand, PutCommand, GetCommand } = require('@aws-sdk/lib-dynamodb');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const { randomUUID } = require('crypto');
const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sqs = new SQSClient({});
const TABLE = process.env.TABLE_NAME || 'carrito-freshbox';
const QUEUE_URL = process.env.QUEUE_URL;
const H = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS' };
const resp = (statusCode, body) => ({ statusCode, headers: H, body: JSON.stringify(body) });

exports.handler = async (event) => {
  try {
    if (event.httpMethod === 'GET') {
      const orderId = event.pathParameters && event.pathParameters.orderId;
      if (!orderId) return resp(400, { error: 'orderId requerido' });
      const r = await doc.send(new GetCommand({ TableName: TABLE, Key: { userId: 'ORDER#' + orderId, productId: 'STATUS' } }));
      if (!r.Item) return resp(404, { error: 'Orden no encontrada' });
      const { estado, total } = r.Item;
      return resp(200, { orderId, estado, total, mensaje: estado === 'procesado' ? 'Su pedido fue procesado' : 'Su pedido fue recibido y esta en proceso' });
    }
    if (event.httpMethod !== 'POST') return resp(405, { error: 'Metodo no permitido' });
    const { userId } = JSON.parse(event.body || '{}');
    if (!userId || !/^[A-Za-z0-9_-]{3,64}$/.test(userId)) return resp(400, { error: 'Campo obligatorio: userId' });
    const cart = await doc.send(new QueryCommand({ TableName: TABLE, KeyConditionExpression: 'userId = :u', ExpressionAttributeValues: { ':u': userId } }));
    const items = (cart.Items || []).map(i => ({ productId: i.productId, nombre: i.nombre, precio: i.precio, cantidad: i.cantidad }));
    if (items.length === 0) return resp(400, { error: 'Carrito vacio', userId });
    const total = items.reduce((s, i) => s + i.precio * i.cantidad, 0);
    const orderId = 'ORD-' + randomUUID();
    // Registro de estado (expira solo por TTL). Process-Order lo pasa a "procesado".
    await doc.send(new PutCommand({ TableName: TABLE, Item: { userId: 'ORDER#' + orderId, productId: 'STATUS', estado: 'pendiente', total, owner: userId, expiresAt: Math.floor(Date.now() / 1000) + 86400 } }));
    await sqs.send(new SendMessageCommand({ QueueUrl: QUEUE_URL, MessageBody: JSON.stringify({ orderId, userId, items, total, createdAt: new Date().toISOString() }) }));
    return resp(200, { message: 'Su pedido fue recibido', orderId, total, cantidadItems: items.length, estado: 'pendiente' });
  } catch (e) { console.error(e); return resp(500, { error: 'Error al crear orden' }); }
};
