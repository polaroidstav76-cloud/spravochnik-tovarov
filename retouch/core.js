/* Ретушь фото: ядро без DOM. Работает в браузере, в воркере и в Node.
 * Автоматика — без изменений из исходной программы «Ретушь фото».
 * Retouch.run(rgba, w, h, opts) -> { data: Uint8ClampedArray, info }
 *   rgba: Uint8ClampedArray (RGBA), opts: smooth, blemish, tone, fresh, texture, eyes, hair (0..100)
 * Retouch.heal(rgba, w, h, x, y, r) — точечная ручная ретушь (меняет rgba на месте),
 *   возвращает {x0, y0, w, h} изменённого прямоугольника.
 */
(function (root) {
  'use strict';

  // ---------- базовые операции ----------
  function boxBlur(src, w, h, r) {
    r = Math.max(1, Math.round(r));
    const tmp = new Float32Array(w * h);
    const out = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      const row = y * w;
      let lo = 0, hi = Math.min(r, w - 1), sum = 0;
      for (let i = 0; i <= hi; i++) sum += src[row + i];
      for (let x = 0; x < w; x++) {
        const nlo = Math.max(0, x - r), nhi = Math.min(w - 1, x + r);
        while (hi < nhi) { hi++; sum += src[row + hi]; }
        while (lo < nlo) { sum -= src[row + lo]; lo++; }
        tmp[row + x] = sum / (hi - lo + 1);
      }
    }
    const col = new Float64Array(w);
    let lo = 0, hi = Math.min(r, h - 1);
    for (let i = 0; i <= hi; i++) { const o = i * w; for (let x = 0; x < w; x++) col[x] += tmp[o + x]; }
    for (let y = 0; y < h; y++) {
      const nlo = Math.max(0, y - r), nhi = Math.min(h - 1, y + r);
      while (hi < nhi) { hi++; const o = hi * w; for (let x = 0; x < w; x++) col[x] += tmp[o + x]; }
      while (lo < nlo) { const o = lo * w; for (let x = 0; x < w; x++) col[x] -= tmp[o + x]; lo++; }
      const cnt = hi - lo + 1, o = y * w;
      for (let x = 0; x < w; x++) out[o + x] = col[x] / cnt;
    }
    return out;
  }

  function maskedBlur(v, m, w, h, r) {
    const n = w * h, vm = new Float32Array(n);
    for (let i = 0; i < n; i++) vm[i] = v[i] * m[i];
    const a = boxBlur(vm, w, h, r), b = boxBlur(m, w, h, r);
    for (let i = 0; i < n; i++) a[i] = a[i] / Math.max(b[i], 1e-3);
    return a;
  }

  // Guided filter: гид I (яркость), фильтруем несколько плоскостей
  function guided(I, planes, w, h, r, eps) {
    const n = w * h;
    const meanI = boxBlur(I, w, h, r);
    const tmp = new Float32Array(n);
    for (let i = 0; i < n; i++) tmp[i] = I[i] * I[i];
    const varI = boxBlur(tmp, w, h, r);
    for (let i = 0; i < n; i++) varI[i] = varI[i] - meanI[i] * meanI[i];
    const outs = [];
    for (const p of planes) {
      const meanP = boxBlur(p, w, h, r);
      for (let i = 0; i < n; i++) tmp[i] = I[i] * p[i];
      const corrIp = boxBlur(tmp, w, h, r);
      const a = new Float32Array(n), b = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        const cov = corrIp[i] - meanI[i] * meanP[i];
        const ai = cov / (varI[i] + eps);
        a[i] = ai; b[i] = meanP[i] - ai * meanI[i];
      }
      const ma = boxBlur(a, w, h, r), mb = boxBlur(b, w, h, r);
      const q = new Float32Array(n);
      for (let i = 0; i < n; i++) q[i] = ma[i] * I[i] + mb[i];
      outs.push(q);
    }
    return outs;
  }

  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function smoothstep(a, b, x) { const t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t); }

  // ---------- маски ----------
  function skinMask(Y, Cb, Cr, R, G, B, n) {
    const m = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const ok = Cr[i] > 133 && Cr[i] < 177 && Cb[i] > 77 && Cb[i] < 128 &&
        Y[i] > 95 && R[i] > G[i] && G[i] > B[i] * 0.85;
      m[i] = ok ? 1 : 0;
    }
    return m;
  }

  // оценка размера лица (ширина) и положения
  function faceGeometry(skin, w, h) {
    const runs = new Int32Array(h);
    const runCenter = new Float32Array(h);
    for (let y = 0; y < h; y++) {
      let best = 0, bestC = 0, cur = 0;
      for (let x = 0; x <= w; x++) {
        if (x < w && skin[y * w + x] > 0.5) cur++;
        else { if (cur > best) { best = cur; bestC = x - cur / 2; } cur = 0; }
      }
      runs[y] = best; runCenter[y] = bestC;
    }
    let y0 = -1;
    for (let y = 0; y < h; y++) { if (runs[y] > 0.06 * w) { y0 = y; break; } }
    if (y0 < 0) return null;
    let fs = 0, cx = 0, cnt = 0;
    const yEnd = Math.min(h - 1, y0 + Math.round(0.30 * h));
    for (let y = y0; y <= yEnd; y++) if (runs[y] > fs) fs = runs[y];
    for (let y = y0; y <= yEnd; y++) if (runs[y] > fs * 0.8) { cx += runCenter[y]; cnt++; }
    cx = cx / Math.max(1, cnt);
    fs = Math.max(0.12 * w, Math.min(0.7 * w, fs));
    return { y0, fs, cx };
  }

  // центры глаз: тёмные «дыры» в маске кожи в полосе глаз слева и справа от центра лица
  function findEyes(prot, w, h, info) {
    const fs = info.fs, cx = info.cx, y0 = info.y0;
    const ya = Math.round(y0 + 0.43 * fs), yb = Math.round(y0 + 0.60 * fs);
    const res = [];
    for (const side of [-1, 1]) {
      let sw = 0, sxx = 0, syy = 0;
      const xa = Math.round(side < 0 ? cx - 0.5 * fs : cx + 0.06 * fs);
      const xb = Math.round(side < 0 ? cx - 0.06 * fs : cx + 0.5 * fs);
      for (let y = Math.max(0, ya); y <= Math.min(h - 1, yb); y++) for (let x = Math.max(0, xa); x <= Math.min(w - 1, xb); x++) {
        const v = prot[y * w + x];
        if (v > 0.3) { sw += v; sxx += v * x; syy += v * y; }
      }
      if (sw < fs * fs * 0.0008) return null;
      res.push({ x: sxx / sw, y: syy / sw });
    }
    return res;
  }

  // ---------- кожа ----------
  function retouchSkin(planes, w, h, o, info) {
    const { Y, Cb, Cr, skinBin } = planes;
    const n = w * h;
    const fs = info.fs;

    // чистим бинарную маску и растушёвываем
    const bgm = new Float32Array(n);
    for (let i = 0; i < n; i++) bgm[i] = (Y[i] > 225 && Math.abs(Cb[i] - 128) < 10 && Math.abs(Cr[i] - 128) < 10) ? 1 : 0;
    const bgNear = boxBlur(bgm, w, h, Math.max(3, fs * 0.012));
    let m = boxBlur(skinBin, w, h, Math.max(2, fs * 0.006));
    for (let i = 0; i < n; i++) m[i] = smoothstep(0.35, 0.75, m[i]);
    m = boxBlur(m, w, h, Math.max(2, fs * 0.008));

    // защита тёмных деталей (брови, ресницы, зрачки, ноздри, губы)
    const localY = maskedBlur(Y, m, w, h, fs * 0.08);
    const prot = new Float32Array(n);
    for (let i = 0; i < n; i++) prot[i] = clamp01((localY[i] - Y[i] - 28) / 22);
    const protD = boxBlur(prot, w, h, Math.max(2, fs * 0.007));
    for (let i = 0; i < n; i++) m[i] = m[i] * (1 - clamp01(protD[i] * 3)) * (1 - clamp01(bgNear[i] * 8));

    const s = o.smooth, b = o.blemish, t = o.tone, tx = o.texture;
    const r = Math.max(3, Math.round(fs * 0.022));
    const eps = Math.pow(10 + 28 * s, 2);
    const [Ys, Cbs, Crs] = guided(Y, [Y, Cb, Cr], w, h, r, eps);

    // защита губ: заметно «краснее» окружающей кожи на большом масштабе
    const CrBig0 = maskedBlur(Crs, m, w, h, fs * 0.12);
    const lip = new Float32Array(n);
    const mcx = info.cx, mcy = info.y0 + 0.88 * fs;
    for (let y = 0; y < h; y++) {
      const ey = (y - mcy) / (0.16 * fs);
      if (ey < -2 || ey > 2) continue;
      for (let x = 0; x < w; x++) {
        const ex = (x - mcx) / (0.34 * fs);
        const e = Math.sqrt(ex * ex + ey * ey);
        if (e > 1.6) continue;
        const i = y * w + x;
        lip[i] = smoothstep(4, 9, Crs[i] - CrBig0[i]) * (1 - smoothstep(1.0, 1.6, e));
      }
    }
    const lipD = boxBlur(lip, w, h, Math.max(2, fs * 0.012));
    for (let i = 0; i < n; i++) m[i] *= 1 - clamp01(lipD[i] * 2.2);
    info.skinMask = m;

    // детализация: мелкая текстура остаётся, крупные выбросы (прыщи) подавляются
    const c = 14 - 8 * b;              // чем сильнее «дефекты», тем меньше допускаем выбросов
    const keep = 0.35 + 0.6 * tx;      // сколько текстуры оставить
    const chromaKeep = 0.40 - 0.34 * b;
    const Yp = new Float32Array(n), Cbp = new Float32Array(n), Crp = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const dY = Y[i] - Ys[i];
      Yp[i] = Ys[i] + keep * c * Math.tanh(dY / c);
      Cbp[i] = Cbs[i] + chromaKeep * (Cb[i] - Cbs[i]);
      Crp[i] = Crs[i] + chromaKeep * (Cr[i] - Crs[i]);
    }

    // выравнивание тона: средние масштабы цветовых пятен -> к общему цвету
    if (t > 0) {
      const rMid = Math.max(4, fs * 0.035), rBig = Math.max(8, fs * 0.14);
      const CbMid = maskedBlur(Cbp, m, w, h, rMid), CbBig = maskedBlur(Cbp, m, w, h, rBig);
      const CrMid = maskedBlur(Crp, m, w, h, rMid), CrBig = maskedBlur(Crp, m, w, h, rBig);
      const YMid = maskedBlur(Yp, m, w, h, rMid), YBig = maskedBlur(Yp, m, w, h, rBig);
      for (let i = 0; i < n; i++) {
        // ограничиваем поправку, чтобы сильные детали (губы, румянец) сохранили цвет
        Cbp[i] -= t * 0.95 * 3.5 * Math.tanh((CbMid[i] - CbBig[i]) / 3.5);
        Crp[i] -= t * 0.95 * 4.5 * Math.tanh((CrMid[i] - CrBig[i]) / 4.5);
        Yp[i] -= t * 0.5 * 5 * Math.tanh((YMid[i] - YBig[i]) / 5);
      }
    }

    // круги под глазами
    const eo = o.eyes;
    if (eo > 0) {
      const eyes = findEyes(prot, w, h, info);
      info.eyes = eyes;
      if (eyes) {
        const YB = maskedBlur(Yp, m, w, h, fs * 0.16);
        const CbB = maskedBlur(Cbp, m, w, h, fs * 0.16), CrB = maskedBlur(Crp, m, w, h, fs * 0.16);
        const sx = 0.14 * fs, sy = 0.05 * fs;
        for (const e of eyes) {
          const ecx = e.x, ecy = e.y + 0.085 * fs;
          const xa = Math.max(0, Math.floor(ecx - 3 * sx)), xb = Math.min(w - 1, Math.ceil(ecx + 3 * sx));
          const ya = Math.max(0, Math.floor(ecy - 3 * sy)), yb = Math.min(h - 1, Math.ceil(ecy + 3 * sy));
          for (let y = ya; y <= yb; y++) for (let x = xa; x <= xb; x++) {
            const i = y * w + x;
            const dx = (x - ecx) / sx, dy = (y - ecy) / sy;
            const wg = Math.exp(-(dx * dx + dy * dy) / 2) * eo;
            const lift = Math.max(0, YB[i] - Yp[i]);
            Yp[i] += wg * 0.85 * lift;
            Cbp[i] += wg * 0.7 * (CbB[i] - Cbp[i]);
            Crp[i] += wg * 0.5 * (CrB[i] - Crp[i]);
          }
        }
      }
    }

    // свежесть: лёгкое осветление, немного убрать жирный блеск
    const f = o.fresh;
    if (f > 0) {
      const rS = Math.max(4, fs * 0.05);
      const Yloc = maskedBlur(Yp, m, w, h, rS);
      for (let i = 0; i < n; i++) {
        const hi = Yp[i] - Yloc[i];
        const matte = hi > 6 ? -f * 0.35 * (hi - 6) : 0; // приглушить блики
        Yp[i] = Yp[i] * (1 + 0.07 * f) + 5 * f + matte;
        Crp[i] = 128 + (Crp[i] - 128) * (1 - 0.06 * f);   // чуть меньше красноты
      }
    }
    return { Yp, Cbp, Crp, mask: m };
  }

  // ---------- волосы ----------
  function hairVolume(rgba, planes, w, h, o, info) {
    const { Y, Cb, Cr, skinBin } = planes;
    const n = w * h, fs = info.fs;
    const amount = o.hair;
    if (amount <= 0) return null;

    // фон: светлый и нейтральный
    const bg = new Uint8Array(n);
    let borderBg = 0, borderN = 0;
    for (let i = 0; i < n; i++) bg[i] = (Y[i] > 225 && Math.abs(Cb[i] - 128) < 10 && Math.abs(Cr[i] - 128) < 10) ? 1 : 0;
    for (let x = 0; x < w; x++) { borderBg += bg[x]; borderN++; }
    for (let y = 0; y < h; y += 4) { borderBg += bg[y * w] + bg[y * w + w - 1]; borderN += 2; }
    if (borderBg / borderN < 0.6) { info.hairNote = 'Фон не однотонный светлый — объём волос отключён'; return null; }

    const y0 = info.y0, cx = info.cx;
    const yTop = Math.max(0, Math.round(y0 - 0.9 * fs));
    const chinY = y0 + 1.2 * fs;
    const yBot = Math.min(h - 1, Math.round(chinY + 0.45 * fs));

    // кандидаты в волосы
    const cand = new Uint8Array(n);
    for (let y = yTop; y <= yBot; y++) for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (!bg[i] && skinBin[i] < 0.5 && Y[i] < 135) cand[i] = 1;
    }
    // связная область, касающаяся верха головы (затравка над лбом)
    const lab = new Uint8Array(n);
    const stack = new Int32Array(n);
    let sp = 0;
    const seedY0 = Math.max(yTop, Math.round(y0 - 0.35 * fs)), seedY1 = Math.max(seedY0 + 1, Math.round(y0 - 0.02 * fs));
    for (let y = seedY0; y <= seedY1; y++) for (let x = Math.round(cx - 0.25 * fs); x <= Math.round(cx + 0.25 * fs); x++) {
      if (x < 0 || x >= w) continue; const i = y * w + x;
      if (cand[i] && !lab[i]) { lab[i] = 1; stack[sp++] = i; }
    }
    if (sp === 0) { info.hairNote = 'Волосы не найдены'; return null; }
    while (sp > 0) {
      const i = stack[--sp], x = i % w, y = (i - x) / w;
      if (x > 0 && cand[i - 1] && !lab[i - 1]) { lab[i - 1] = 1; stack[sp++] = i - 1; }
      if (x < w - 1 && cand[i + 1] && !lab[i + 1]) { lab[i + 1] = 1; stack[sp++] = i + 1; }
      if (y > yTop && cand[i - w] && !lab[i - w]) { lab[i - w] = 1; stack[sp++] = i - w; }
      if (y < yBot && cand[i + w] && !lab[i + w]) { lab[i + w] = 1; stack[sp++] = i + w; }
    }
    const hair = new Float32Array(n);
    for (let i = 0; i < n; i++) hair[i] = lab[i];
    info.hairMask = hair;

    // расстояние от края волос наружу (chamfer), нормаль = градиент расстояния
    const skinNear = boxBlur(skinBin, w, h, Math.max(3, fs * 0.02));
    const maxShift = (amount * 0.075) * fs;      // макс. наращивание силуэта, px
    const cap = Math.ceil(maxShift + 4);
    const dist = new Float32Array(n);
    const INF = 1e6;
    for (let i = 0; i < n; i++) dist[i] = hair[i] > 0.5 ? 0 : INF;
    const ya0 = Math.max(1, yTop - cap), yb0 = Math.min(h - 2, yBot + cap);
    for (let y = ya0; y <= yb0; y++) for (let x = 1; x < w - 1; x++) {
      const i = y * w + x; let d = dist[i]; if (d === 0) continue;
      const a1 = dist[i - 1] + 1, a2 = dist[i - w] + 1, a3 = dist[i - w - 1] + 1.414, a4 = dist[i - w + 1] + 1.414;
      if (a1 < d) d = a1; if (a2 < d) d = a2; if (a3 < d) d = a3; if (a4 < d) d = a4;
      dist[i] = d;
    }
    for (let y = yb0; y >= ya0; y--) for (let x = w - 2; x >= 1; x--) {
      const i = y * w + x; let d = dist[i]; if (d === 0) continue;
      const a1 = dist[i + 1] + 1, a2 = dist[i + w] + 1, a3 = dist[i + w - 1] + 1.414, a4 = dist[i + w + 1] + 1.414;
      if (a1 < d) d = a1; if (a2 < d) d = a2; if (a3 < d) d = a3; if (a4 < d) d = a4;
      dist[i] = d;
    }
    const dcap = new Float32Array(n);
    for (let i = 0; i < n; i++) dcap[i] = dist[i] > cap ? cap : dist[i];
    const dsm = boxBlur(boxBlur(dcap, w, h, Math.max(2, fs * 0.012)), w, h, Math.max(2, fs * 0.012));

    const cy = y0 + 0.6 * fs;
    const out = new Uint8ClampedArray(rgba.length);
    out.set(rgba);
    let moved = 0;
    const gpx = Math.max(2, Math.round(fs * 0.015));
    for (let y = ya0; y <= yb0; y++) {
      const vFade = 1 - smoothstep(chinY - 0.1 * fs, yBot, y);
      if (vFade <= 0) continue;
      for (let x = gpx; x < w - gpx; x++) {
        const i = y * w + x;
        if (dist[i] <= 0 || dist[i] >= cap) continue;
        const t = dsm[i];
        if (t <= 0.3) continue;
        // сила в этой точке
        let rx0 = x - cx, ry0 = y - cy;
        const ex = rx0 / (0.60 * fs), ey = ry0 / (0.72 * fs);
        const wFace = smoothstep(0.92, 1.2, Math.sqrt(ex * ex + ey * ey));
        if (wFace <= 0) continue;
        const wSkin = 1 - clamp01(skinNear[i] * 2.5);
        const D = maxShift * wFace * wSkin * vFade;
        if (t >= D) continue;
        let gx = dsm[i + gpx] - dsm[i - gpx], gy = dsm[i + gpx * w] - dsm[i - gpx * w];
        const gl = Math.hypot(gx, gy);
        if (gl < 1e-4) continue;
        const nx = gx / gl, ny = gy / gl;           // от волос наружу
        const rl = Math.hypot(rx0, ry0) || 1;
        const radial = clamp01(((nx * rx0 + ny * ry0) / rl) * 2);
        if (radial <= 0) continue;
        const Dr = D * radial;
        if (t >= Dr) continue;
        const dl = 2 * t + fs * 0.01;
        const sx = x - nx * dl, sy = y - ny * dl;   // зеркальная точка внутри волос (с отступом от кромки)
        const x0 = Math.floor(sx), y1 = Math.floor(sy);
        if (x0 < 0 || y1 < 0 || x0 >= w - 1 || y1 >= h - 1) continue;
        const fx = sx - x0, fy = sy - y1;
        const i00 = (y1 * w + x0) * 4, i10 = i00 + 4, i01 = i00 + w * 4, i11 = i01 + 4;
        const al = 1 - smoothstep(0.5 * Dr, Dr, t);
        const o4 = i * 4;
        for (let ch = 0; ch < 3; ch++) {
          const v = (rgba[i00 + ch] * (1 - fx) + rgba[i10 + ch] * fx) * (1 - fy) +
            (rgba[i01 + ch] * (1 - fx) + rgba[i11 + ch] * fx) * fy;
          out[o4 + ch] = rgba[o4 + ch] * (1 - al) + v * al;
        }
        moved++;
      }
    }
    info.hairMoved = moved;
    return out;
  }

  // ---------- главный вход ----------
  function run(rgba, w, h, opts) {
    const o = Object.assign({ smooth: 55, blemish: 70, tone: 60, fresh: 30, texture: 50, eyes: 50, hair: 30, strength: 100 }, opts || {});
    for (const k of ['smooth', 'blemish', 'tone', 'fresh', 'texture', 'eyes', 'hair', 'strength']) o[k] = clamp01(o[k] / 100);
    const n = w * h;
    const R = new Float32Array(n), G = new Float32Array(n), B = new Float32Array(n);
    const Y = new Float32Array(n), Cb = new Float32Array(n), Cr = new Float32Array(n);
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const r = rgba[j], g = rgba[j + 1], b = rgba[j + 2];
      R[i] = r; G[i] = g; B[i] = b;
      Y[i] = 0.299 * r + 0.587 * g + 0.114 * b;
      Cb[i] = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
      Cr[i] = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    }
    const skinBin = skinMask(Y, Cb, Cr, R, G, B, n);
    const info = {};
    const geo = faceGeometry(skinBin, w, h);
    if (!geo) { info.error = 'Лицо не найдено'; return { data: new Uint8ClampedArray(rgba), info }; }
    Object.assign(info, geo);

    const planes = { Y, Cb, Cr, skinBin };
    const sk = retouchSkin(planes, w, h, o, info);
    const out = new Uint8ClampedArray(rgba.length);
    const a = o.strength;
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const wgt = sk.mask[i] * a;
      const y = sk.Yp[i], cb = sk.Cbp[i] - 128, cr = sk.Crp[i] - 128;
      const r = y + 1.402 * cr, g = y - 0.344136 * cb - 0.714136 * cr, b = y + 1.772 * cb;
      out[j] = rgba[j] * (1 - wgt) + r * wgt;
      out[j + 1] = rgba[j + 1] * (1 - wgt) + g * wgt;
      out[j + 2] = rgba[j + 2] * (1 - wgt) + b * wgt;
      out[j + 3] = rgba[j + 3];
    }
    // волосы считаем по исходным плоскостям, применяем поверх результата кожи
    const hairOut = hairVolume(out, planes, w, h, o, info);
    return { data: hairOut || out, info };
  }

  // ---------- ручная ретушь: «заплатка» как восстанавливающая кисть ----------
  // Цвет внутри круга интерполируется с его границы, а мелкая текстура берётся с соседнего чистого участка.
  function heal(rgba, w, h, cx, cy, r) {
    r = Math.max(2, r);
    const R2 = r * 1.35, pad = Math.ceil(R2) + 2;
    const x0 = Math.max(0, Math.floor(cx - pad)), x1 = Math.min(w - 1, Math.ceil(cx + pad));
    const y0 = Math.max(0, Math.floor(cy - pad)), y1 = Math.min(h - 1, Math.ceil(cy + pad));
    if (x1 <= x0 || y1 <= y0) return null;

    const px = (x, y, ch) => rgba[((y < 0 ? 0 : y >= h ? h - 1 : y) * w + (x < 0 ? 0 : x >= w ? w - 1 : x)) * 4 + ch];
    // средний цвет в маленьком окне
    function avg(x, y, rad) {
      const s = [0, 0, 0]; let c = 0;
      const xi = Math.round(x), yi = Math.round(y);
      for (let dy = -rad; dy <= rad; dy++) for (let dx = -rad; dx <= rad; dx++) {
        s[0] += px(xi + dx, yi + dy, 0); s[1] += px(xi + dx, yi + dy, 1); s[2] += px(xi + dx, yi + dy, 2); c++;
      }
      return [s[0] / c, s[1] / c, s[2] / c];
    }

    // точки на кольце чуть снаружи пятна; выбросы (тёмные/яркие пятна на кольце) отбрасываем
    const K = 32, ring = [], rr = r * 1.18, sr = Math.max(1, Math.round(r * 0.12));
    for (let k = 0; k < K; k++) {
      const a = (k / K) * Math.PI * 2;
      const x = cx + Math.cos(a) * rr, y = cy + Math.sin(a) * rr;
      ring.push({ x, y, c: avg(x, y, sr) });
    }
    const lum = c => 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
    const ls = ring.map(p => lum(p.c)).sort((a, b) => a - b);
    const med = ls[K >> 1], mad = Math.max(3, ls.map(v => Math.abs(v - med)).sort((a, b) => a - b)[K >> 1] * 2.5);
    let good = ring.filter(p => Math.abs(lum(p.c) - med) <= mad);
    if (good.length < 6) good = ring;
    const ringMean = [0, 1, 2].map(ch => good.reduce((s, p) => s + p.c[ch], 0) / good.length);

    // источник текстуры: соседний участок той же яркости и с ровной текстурой
    let best = null;
    for (let k = 0; k < 8; k++) {
      const a = (k / 8) * Math.PI * 2, d = r * 3.2;
      const sx = Math.round(cx + Math.cos(a) * d), sy = Math.round(cy + Math.sin(a) * d);
      if (sx - r < 0 || sy - r < 0 || sx + r >= w || sy + r >= h) continue;
      let s = 0, s2 = 0, c = 0;
      const st = Math.max(1, Math.round(r / 6));
      for (let dy = -r; dy <= r; dy += st) for (let dx = -r; dx <= r; dx += st) {
        if (dx * dx + dy * dy > r * r) continue;
        const v = 0.299 * px(sx + dx, sy + dy, 0) + 0.587 * px(sx + dx, sy + dy, 1) + 0.114 * px(sx + dx, sy + dy, 2);
        s += v; s2 += v * v; c++;
      }
      const m = s / c, sd = Math.sqrt(Math.max(0, s2 / c - m * m));
      const score = Math.abs(m - lum(ringMean)) + 1.5 * sd;
      if (!best || score < best.score) best = { sx, sy, score, sd };
    }

    const bw = x1 - x0 + 1, bh = y1 - y0 + 1;
    const before = new Uint8ClampedArray(bw * bh * 4);
    for (let y = y0; y <= y1; y++) before.set(rgba.subarray((y * w + x0) * 4, (y * w + x1 + 1) * 4), (y - y0) * bw * 4);

    const tr = Math.max(1, Math.round(r / 3));
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      const d = Math.hypot(x - cx, y - cy);
      if (d >= R2) continue;
      const al = 1 - smoothstep(r, R2, d);
      // плавная интерполяция по точкам кольца (обратные расстояния)
      let ws = 0; const v = [0, 0, 0];
      for (const p of good) {
        const dd = (x - p.x) * (x - p.x) + (y - p.y) * (y - p.y) + 1;
        const wt = 1 / (dd * dd);
        ws += wt; v[0] += wt * p.c[0]; v[1] += wt * p.c[1]; v[2] += wt * p.c[2];
      }
      v[0] /= ws; v[1] /= ws; v[2] /= ws;
      if (best && best.sd < 18) {
        const ox = best.sx - cx, oy = best.sy - cy;
        const sxp = Math.round(x + ox), syp = Math.round(y + oy);
        const loc = avg(sxp, syp, tr);
        for (let ch = 0; ch < 3; ch++) v[ch] += 0.85 * (px(sxp, syp, ch) - loc[ch]);
      }
      const j = (y * w + x) * 4;
      const bj = ((y - y0) * bw + (x - x0)) * 4;
      for (let ch = 0; ch < 3; ch++) rgba[j + ch] = before[bj + ch] * (1 - al) + v[ch] * al;
    }
    return { x0, y0, w: bw, h: bh };
  }

  root.Retouch = { run, heal, boxBlur, guided };
  if (typeof module !== 'undefined') module.exports = root.Retouch;
})(typeof self !== 'undefined' ? self : typeof window !== 'undefined' ? window : globalThis);
