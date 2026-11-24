// FreshBox SpA - Frontend S3 (EP3). API_URL se inyecta al publicar (scripts/11-frontend.sh).
const API_URL = "https://8wwgvuu2i8.execute-api.us-east-1.amazonaws.com/prod";
const USER_ID = (() => { try { let u = localStorage.getItem('fb_user'); if (!u) { u = 'user-' + Math.random().toString(36).slice(2, 8); localStorage.setItem('fb_user', u); } return u; } catch (e) { return 'user-' + Math.random().toString(36).slice(2, 8); } })();
const $ = (id) => document.getElementById(id);
const money = (n) => '$' + Number(n).toLocaleString('es-CL');
function msg(t, tipo) { const m = $('mensaje'); m.textContent = t; m.className = tipo === 'exito' ? 'mensaje-exito' : 'mensaje-error'; setTimeout(() => { m.textContent = ''; m.className = ''; }, 6000); }
async function api(path, opts) {
  const r = await fetch(API_URL + path, opts);
  let data = null; try { data = await r.json(); } catch (e) { /* sin cuerpo */ }
  if (!r.ok) throw new Error((data && data.error) || ('HTTP ' + r.status));
  return data;
}
const json = (method, body) => ({ method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
function cell(tr, text) { const td = document.createElement('td'); td.textContent = text; tr.appendChild(td); return td; }
function btn(label, cls, fn) { const b = document.createElement('button'); b.className = cls; b.textContent = label; b.addEventListener('click', fn); return b; }

document.addEventListener('DOMContentLoaded', cargarProductos);

async function cargarProductos() {
  try { renderizarTabla(await api('/api/products')); } catch (e) { msg('Error al cargar productos: ' + e.message, 'error'); }
}
function renderizarTabla(productos) {
  const tbody = $('productos-body'); tbody.replaceChildren();
  productos.forEach((p) => {
    const tr = document.createElement('tr');
    [p.id, p.nombre, p.descripcion || '-', money(p.precio), p.stock, p.categoria || '-'].forEach((v) => cell(tr, v));
    const acc = document.createElement('td');
    acc.append(btn('+ Carrito', 'btn-carrito', () => agregarCarrito(p)), ' ', btn('Editar', 'btn-editar', () => editarProducto(p)), ' ', btn('Eliminar', 'btn-eliminar', () => eliminarProducto(p.id)));
    tr.appendChild(acc); tbody.appendChild(tr);
  });
}
async function guardarProducto(ev) {
  ev.preventDefault();
  const id = $('producto-id').value;
  const datos = { nombre: $('nombre').value, descripcion: $('descripcion').value, precio: parseFloat($('precio').value), stock: parseInt($('stock').value, 10), categoria: $('categoria').value };
  try {
    await api(id ? '/api/products/' + id : '/api/products', json(id ? 'PUT' : 'POST', datos));
    msg(id ? 'Producto modificado' : 'Producto creado', 'exito'); limpiarFormulario(); cargarProductos();
  } catch (e) { msg('No se pudo guardar: ' + e.message, 'error'); }
}
async function eliminarProducto(id) {
  if (!confirm('Eliminar producto ' + id + '?')) return;
  try { await api('/api/products/' + id, { method: 'DELETE' }); msg('Producto eliminado', 'exito'); cargarProductos(); } catch (e) { msg('No se pudo eliminar: ' + e.message, 'error'); }
}
function editarProducto(p) {
  $('producto-id').value = p.id; $('nombre').value = p.nombre; $('descripcion').value = p.descripcion || ''; $('precio').value = p.precio; $('stock').value = p.stock; $('categoria').value = p.categoria || '';
  $('form-titulo').textContent = 'Editar (ID:' + p.id + ')';
}
function cancelarEdicion() { limpiarFormulario(); }
function limpiarFormulario() { $('producto-form').reset(); $('producto-id').value = ''; $('form-titulo').textContent = 'Nuevo Producto'; }

async function agregarCarrito(p) {
  try { await api('/api/cart', json('POST', { userId: USER_ID, productId: String(p.id), nombre: p.nombre, precio: Number(p.precio), cantidad: 1 })); msg('Agregado al carrito', 'exito'); verCarrito(); }
  catch (e) { msg('No se pudo agregar: ' + e.message, 'error'); }
}
async function verCarrito() {
  const div = $('carrito-contenido');
  try {
    const data = await api('/api/cart?userId=' + encodeURIComponent(USER_ID));
    div.replaceChildren();
    if (!data.items.length) { div.textContent = 'Carrito vacio'; return; }
    const ul = document.createElement('ul');
    data.items.forEach((i) => { const li = document.createElement('li'); li.textContent = i.nombre + ' x' + i.cantidad + ' - ' + money(i.precio * i.cantidad) + ' '; li.appendChild(btn('X', 'btn-eliminar', () => quitarCarrito(i.productId))); ul.appendChild(li); });
    const tot = document.createElement('p'); const s = document.createElement('strong'); s.textContent = 'Total: ' + money(data.total); tot.appendChild(s);
    div.append(ul, tot, btn('Confirmar Pedido', 'btn-orden', crearOrden));
  } catch (e) { msg('No se pudo leer el carrito: ' + e.message, 'error'); }
}
async function quitarCarrito(productId) {
  try { await api('/api/cart/' + encodeURIComponent(productId) + '?userId=' + encodeURIComponent(USER_ID), { method: 'DELETE' }); verCarrito(); } catch (e) { msg('No se pudo quitar: ' + e.message, 'error'); }
}
async function crearOrden() {
  try {
    const o = await api('/api/orders', json('POST', { userId: USER_ID }));
    msg('Pedido recibido (' + o.orderId + '). Procesando...', 'exito');
    // La orden se procesa de forma asincrona (SQS -> Lambda -> MySQL): se consulta su estado hasta confirmarla
    for (let n = 0; n < 20; n++) {
      await new Promise((r) => setTimeout(r, 2000));
      const s = await api('/api/orders/' + encodeURIComponent(o.orderId));
      if (s.estado === 'procesado') { msg('Su pedido fue procesado - Total: ' + money(s.total), 'exito'); verCarrito(); return; }
    }
    msg('El pedido sigue en proceso; consulte nuevamente en unos minutos.', 'error');
  } catch (e) { msg('No se pudo crear la orden: ' + e.message, 'error'); }
}
