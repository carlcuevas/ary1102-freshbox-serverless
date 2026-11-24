// FreshBox - Lambda Cart (EP3). API Gateway REST (proxy) -> DynamoDB con TTL.
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, UpdateCommand, QueryCommand, DeleteCommand } = require('@aws-sdk/lib-dynamodb');
const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME || 'carrito-freshbox';
const TTL_SECONDS = 86400;
const H = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Allow-Methods': 'GET,POST,DELETE,OPTIONS' };
const resp = (statusCode, body) => ({ statusCode, headers: H, body: JSON.stringify(body) });
const validUser = (u) => typeof u === 'string' && /^[A-Za-z0-9_-]{3,64}$/.test(u);

exports.handler = async (event) => {
  const method = event.httpMethod;
  try {
    if (method === 'POST') {
      const { userId, productId, nombre, precio, cantidad } = JSON.parse(event.body || '{}');
      const p = Number(precio), c = Number(cantidad);
      if (!validUser(userId) || !productId || !nombre || !(p > 0) || !Number.isInteger(c) || c < 1)
        return resp(400, { error: 'Campos validos requeridos: userId, productId, nombre, precio>0, cantidad (entero>=1)' });
      // ADD acumula la cantidad si el producto ya estaba en el carrito
      await doc.send(new UpdateCommand({
        TableName: TABLE, Key: { userId, productId: String(productId) },
        UpdateExpression: 'SET nombre = :n, precio = :p, addedAt = :a, expiresAt = :e ADD cantidad :c',
        ExpressionAttributeValues: { ':n': String(nombre).slice(0, 150), ':p': p, ':c': c, ':a': new Date().toISOString(), ':e': Math.floor(Date.now() / 1000) + TTL_SECONDS }
      }));
      return resp(201, { message: 'Producto agregado al carrito', userId, productId: String(productId) });
    }
    if (method === 'GET') {
      const userId = event.queryStringParameters && event.queryStringParameters.userId;
      if (!validUser(userId)) return resp(400, { error: 'Parametro requerido: userId' });
      const r = await doc.send(new QueryCommand({ TableName: TABLE, KeyConditionExpression: 'userId = :u', ExpressionAttributeValues: { ':u': userId } }));
      const items = r.Items || [];
      const total = items.reduce((s, i) => s + i.precio * i.cantidad, 0);
      return resp(200, { userId, items, total, cantidadItems: items.length });
    }
    if (method === 'DELETE') {
      const userId = event.queryStringParameters && event.queryStringParameters.userId;
      const productId = event.pathParameters && event.pathParameters.productId;
      if (!validUser(userId) || !productId) return resp(400, { error: 'Parametros requeridos: userId, productId' });
      await doc.send(new DeleteCommand({ TableName: TABLE, Key: { userId, productId: String(productId) } }));
      return resp(200, { message: 'Producto eliminado del carrito' });
    }
    return resp(405, { error: 'Metodo no permitido' });
  } catch (e) { console.error(e); return resp(500, { error: 'Error interno' }); }
};
