// FreshBox - Lambda Process-Order (EP3). SQS -> RDS MySQL (idempotente por order_id) -> estado + limpia carrito.
const mysql = require('mysql2/promise');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, QueryCommand, BatchWriteCommand, UpdateCommand } = require('@aws-sdk/lib-dynamodb');
const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME || 'carrito-freshbox';
const dbConfig = { host: process.env.DB_HOST, user: process.env.DB_USER, password: process.env.DB_PASS, database: process.env.DB_NAME || 'freshbox', port: parseInt(process.env.DB_PORT || '3306', 10), connectTimeout: 8000 };

exports.handler = async (event) => {
  const batchItemFailures = [];
  let conn;
  try {
    conn = await mysql.createConnection(dbConfig);
    for (const record of event.Records) {
      try {
        const o = JSON.parse(record.body);
        // order_id UNIQUE: si SQS reentrega el mensaje, no se duplica la orden
        await conn.execute(
          "INSERT INTO ordenes (order_id, user_id, total, estado, items, processed_at) VALUES (?, ?, ?, 'procesado', ?, NOW()) ON DUPLICATE KEY UPDATE estado = 'procesado'",
          [o.orderId, o.userId, o.total, JSON.stringify(o.items)]);
        await doc.send(new UpdateCommand({ TableName: TABLE, Key: { userId: 'ORDER#' + o.orderId, productId: 'STATUS' }, UpdateExpression: 'SET estado = :e', ExpressionAttributeValues: { ':e': 'procesado' } }));
        const cart = await doc.send(new QueryCommand({ TableName: TABLE, KeyConditionExpression: 'userId = :u', ExpressionAttributeValues: { ':u': o.userId } }));
        const dels = (cart.Items || []).map(i => ({ DeleteRequest: { Key: { userId: i.userId, productId: i.productId } } }));
        for (let i = 0; i < dels.length; i += 25) await doc.send(new BatchWriteCommand({ RequestItems: { [TABLE]: dels.slice(i, i + 25) } }));
        console.log('Orden procesada', o.orderId);
      } catch (e) { console.error('Fallo mensaje', record.messageId, e.message); batchItemFailures.push({ itemIdentifier: record.messageId }); }
    }
  } catch (e) {
    console.error('Fallo conexion MySQL', e.message);
    return { batchItemFailures: event.Records.map(r => ({ itemIdentifier: r.messageId })) };
  } finally { if (conn) await conn.end().catch(() => {}); }
  return { batchItemFailures };
};
