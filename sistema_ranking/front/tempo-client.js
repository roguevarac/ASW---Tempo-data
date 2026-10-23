/*
 * Cliente del sistema propio de Ranking Digital.
 * Expone window.supabase.createClient(...) con los MISMOS métodos que usa el front
 * (antes provistos por supabase-js), para que el HTML funcione sin cambiar su lógica:
 *
 *   auth.signInWithPassword({email,password}) · auth.getSession() · auth.signOut()
 *   auth.cambiarClave(email, actual, nueva) · auth.restablecerClave(email, codigo, nueva)   (pantalla de ingreso)
 *   from(tabla).select(cols).eq(c,v).is(c,v).order(c,{ascending}).limit(n).range(a,b).single().csv()
 *   from(tabla).update(cambios).eq(c,v) · from(tabla).insert(fila | filas)
 *   rpc(funcion, params).select(cols).range(a,b).single().csv()
 *   storage.from(bucket).upload(ruta, archivo) · storage.from(bucket).createSignedUrl(ruta, segundos)
 *
 * Todas las llamadas devuelven { data, error } como supabase-js.
 *
 * La sesión se renueva sola mientras se usa la aplicación: cuando pasó la mitad de la vigencia del token, el pedido
 * siguiente pide uno nuevo (/auth/renovar). Vence después de SESSION_HOURS sin uso o al cerrar sesión.
 */
(function () {
  const CLAVE_SESION = 'rk_session';

  function leerSesion() {
    try {
      const s = JSON.parse(localStorage.getItem(CLAVE_SESION) || 'null');
      if (s && s.expires_at * 1000 > Date.now() + 5000) return s;
    } catch (e) { /* sesión corrupta */ }
    try { localStorage.removeItem(CLAVE_SESION); } catch (e) { /* sin storage */ }
    return null;
  }

  function guardarSesion(datos) {
    datos.renovar_desde = Math.floor(Date.now() / 1000) + Math.floor((datos.expires_in || 0) / 2);
    localStorage.setItem(CLAVE_SESION, JSON.stringify(datos));
  }

  function createClient(baseUrl) {
    const base = (baseUrl || '').replace(/\/$/, '');
    let renovando = null;

    // Token nuevo para la misma sesión (un solo pedido aunque haya varios en curso).
    function renovar(s) {
      if (!renovando) {
        renovando = fetch(base + '/auth/renovar', { method: 'POST', headers: { Authorization: 'Bearer ' + s.access_token } })
          .then(async (res) => { if (res.ok) guardarSesion(await res.json()); })
          .catch(() => { /* sin conexión: se reintenta en el pedido siguiente */ })
          .finally(() => { renovando = null; });
      }
      return renovando;
    }

    async function pedir(metodo, ruta, { body, accept, raw, contentType } = {}) {
      const headers = {};
      let s = leerSesion();
      if (s && s.renovar_desde && Date.now() / 1000 > s.renovar_desde && !ruta.startsWith('/auth/')) {
        await renovar(s);
        s = leerSesion();
      }
      if (s) headers['Authorization'] = 'Bearer ' + s.access_token;
      if (accept) headers['Accept'] = accept;
      let cuerpo;
      if (raw !== undefined) { cuerpo = raw; headers['Content-Type'] = contentType || 'application/octet-stream'; }
      else if (body !== undefined) { cuerpo = JSON.stringify(body); headers['Content-Type'] = 'application/json'; }
      let res;
      try {
        res = await fetch(base + ruta, { method: metodo, headers, body: cuerpo });
      } catch (e) {
        return { data: null, error: { message: 'No hay conexión con el servidor: ' + e.message } };
      }
      if (res.status === 401 && s) {
        // La sesión venció: se limpia y se vuelve a la pantalla de login.
        localStorage.removeItem(CLAVE_SESION);
        setTimeout(() => location.reload(), 50);
      }
      if (res.status === 204 || res.status === 201 && !(res.headers.get('content-type') || '').includes('json')) {
        return { data: null, error: null };
      }
      const tipo = res.headers.get('content-type') || '';
      const contenido = tipo.includes('json') ? await res.json() : await res.text();
      if (!res.ok) {
        const msg = (contenido && contenido.message) || (typeof contenido === 'string' ? contenido : 'Error ' + res.status);
        return { data: null, error: { message: msg, code: contenido && contenido.code, status: res.status } };
      }
      return { data: contenido, error: null };
    }

    // ---------------------------------------------------------------- consultas
    class Consulta {
      constructor(tipo, nombre, params) {
        this.tipo = tipo;            // 'tabla' | 'rpc'
        this.nombre = nombre;
        this.params = params || {};
        this.metodo = tipo === 'rpc' ? 'POST' : 'GET';
        this.filtros = [];
        this.cols = null;
        this.orden = [];
        this.lim = null;
        this.off = null;
        this.unica = false;
        this.comoCsv = false;
        this.cuerpo = undefined;
      }
      select(cols) { this.cols = cols; return this; }
      eq(c, v) { this.filtros.push([c, 'eq.' + v]); return this; }
      neq(c, v) { this.filtros.push([c, 'neq.' + v]); return this; }
      gt(c, v) { this.filtros.push([c, 'gt.' + v]); return this; }
      gte(c, v) { this.filtros.push([c, 'gte.' + v]); return this; }
      lt(c, v) { this.filtros.push([c, 'lt.' + v]); return this; }
      lte(c, v) { this.filtros.push([c, 'lte.' + v]); return this; }
      like(c, v) { this.filtros.push([c, 'like.' + v]); return this; }
      ilike(c, v) { this.filtros.push([c, 'ilike.' + v]); return this; }
      in(c, vs) { this.filtros.push([c, 'in.(' + vs.join(',') + ')']); return this; }
      is(c, v) { this.filtros.push([c, 'is.' + (v === null ? 'null' : String(v))]); return this; }
      order(c, op) {
        const asc = !op || op.ascending !== false;
        let t = c + (asc ? '.asc' : '.desc');
        if (op && op.nullsFirst === true) t += '.nullsfirst';
        if (op && op.nullsFirst === false) t += '.nullslast';
        this.orden.push(t); return this;
      }
      limit(n) { this.lim = n; return this; }
      range(desde, hasta) { this.off = desde; this.lim = hasta - desde + 1; return this; }
      single() { this.unica = true; return this; }
      csv() { this.comoCsv = true; return this; }
      update(cambios) { this.metodo = 'PATCH'; this.cuerpo = cambios; return this; }
      insert(filas) { this.metodo = 'POST'; this.cuerpo = filas; return this; }

      _ruta() {
        const q = new URLSearchParams();
        if (this.cols) q.append('select', this.cols.replace(/\s+/g, ''));
        for (const [c, v] of this.filtros) q.append(c, v);
        if (this.orden.length) q.append('order', this.orden.join(','));
        if (this.lim !== null) q.append('limit', String(this.lim));
        if (this.off !== null) q.append('offset', String(this.off));
        if (this.unica) q.append('single', '1');
        const qs = q.toString();
        const base = this.tipo === 'rpc' ? '/rpc/' + this.nombre : '/rest/' + this.nombre;
        return base + (qs ? '?' + qs : '');
      }
      async _ejecutar() {
        const accept = this.comoCsv ? 'text/csv' : 'application/json';
        const body = this.tipo === 'rpc' ? this.params : this.cuerpo;
        return pedir(this.metodo, this._ruta(), { body, accept });
      }
      then(ok, mal) { return this._ejecutar().then(ok, mal); }
    }

    // ---------------------------------------------------------------- sesión
    const auth = {
      async signInWithPassword({ email, password }) {
        const r = await pedir('POST', '/auth/login', { body: { email, password } });
        if (r.error) return { data: { session: null, user: null }, error: r.error };
        guardarSesion(r.data);
        return { data: { session: r.data, user: r.data.user }, error: null };
      },
      async getSession() {
        return { data: { session: leerSesion() }, error: null };
      },
      async signOut() {
        // Anula la sesión en el servidor: el token deja de servir aunque alguien lo haya copiado.
        if (leerSesion()) await pedir('POST', '/auth/salir');
        localStorage.removeItem(CLAVE_SESION);
        return { error: null };
      },
      async cambiarClave(email, actual, nueva) {
        const r = await pedir('POST', '/auth/clave', { body: { email, actual, nueva } });
        return { error: r.error };
      },
      async restablecerClave(email, codigo, nueva) {
        const r = await pedir('POST', '/auth/restablecer', { body: { email, codigo, nueva } });
        return { error: r.error };
      },
    };

    // ---------------------------------------------------------------- archivos
    const ruta = (p) => p.split('/').map(encodeURIComponent).join('/');
    const storage = {
      from(bucket) {
        return {
          async upload(path, archivo) {
            return pedir('POST', `/storage/upload/${bucket}/${ruta(path)}`,
              { raw: archivo, contentType: (archivo && archivo.type) || 'application/octet-stream' });
          },
          async createSignedUrl(path, segundos) {
            const r = await pedir('POST', `/storage/sign/${bucket}/${ruta(path)}`, { body: { expiresIn: segundos } });
            if (r.data && r.data.signedUrl && r.data.signedUrl.startsWith('/')) r.data.signedUrl = base + r.data.signedUrl;
            return r;
          },
        };
      },
    };

    return {
      auth,
      storage,
      from: (tabla) => new Consulta('tabla', tabla),
      rpc: (fn, params) => new Consulta('rpc', fn, params),
    };
  }

  window.supabase = { createClient };
})();
