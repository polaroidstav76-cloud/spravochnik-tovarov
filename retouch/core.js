/* Ретушь фото: ядро без DOM. Работает в браузере, в воркере и в Node.
 * Retouch.run(rgba, w, h, opts) -> { data: Uint8ClampedArray, info }
 *   rgba: Uint8ClampedArray (RGBA), opts (0..100):
 *   smooth, blemish, tone, fresh, texture, eyes, hair, clarity, quality, bg
 * Retouch.heal(rgba, w, h, x, y, r) — точечная ручная ретушь (меняет rgba на месте),
 *   возвращает {x0, y0, w, h} изменённого прямоугольника.
 */
(function (root) {
  'use strict';

  // ---------- базовые операции ----------
  // Большие радиусы считаем на уменьшенной копии: результат почти тот же, а быстрее в разы.
  function boxBlur(src, w, h, r) {
    r = Math.max(1, Math.round(r));
    if (r < 10) return boxBlurExact(src, w, h, r);
    const s = Math.floor(r / 5), dw = Math.ceil(w / s), dh = Math.ceil(h / s);
    const small = new Float32Array(dw * dh), cnt = new Float32Array(dw * dh);
    for (let y = 0; y < h; y++) {
      const o = ((y / s) | 0) * dw, row = y * w;
      for (let x = 0; x < w; x++) { const k = o + ((x / s) | 0); small[k] += src[row + x]; cnt[k]++; }
    }
    for (let k = 0; k < small.length; k++) small[k] /= cnt[k];
    const sb = boxBlurExact(small, dw, dh, Math.max(1, Math.round(r / s)));
    const out = new Float32Array(w * h);
    const xi = new Int32Array(w), xf = new Float32Array(w);
    for (let x = 0; x < w; x++) {
      let fx = (x + 0.5) / s - 0.5; if (fx < 0) fx = 0; if (fx > dw - 1) fx = dw - 1;
      xi[x] = Math.min(dw - 2, fx | 0); xf[x] = fx - xi[x];
      if (dw === 1) { xi[x] = 0; xf[x] = 0; }
    }
    for (let y = 0; y < h; y++) {
      let fy = (y + 0.5) / s - 0.5; if (fy < 0) fy = 0; if (fy > dh - 1) fy = dh - 1;
      let yi = Math.min(dh - 2, fy | 0); if (dh === 1) yi = 0;
      const ty = dh === 1 ? 0 : fy - yi, r0 = yi * dw, r1 = dh === 1 ? r0 : r0 + dw, row = y * w;
      for (let x = 0; x < w; x++) {
        const a = xi[x], t = xf[x], a1 = dw === 1 ? a : a + 1;
        const top = sb[r0 + a] + (sb[r0 + a1] - sb[r0 + a]) * t;
        const bot = sb[r1 + a] + (sb[r1 + a1] - sb[r1 + a]) * t;
        out[row + x] = top + (bot - top) * ty;
      }
    }
    return out;
  }

  function boxBlurExact(src, w, h, r) {
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
      const meanP = p === I ? meanI : boxBlur(p, w, h, r);
      for (let i = 0; i < n; i++) tmp[i] = I[i] * p[i];
      const corrIp = boxBlur(tmp, w, h, r);
      const a = new Float32Array(n), b = corrIp;
      for (let i = 0; i < n; i++) {
        const cov = corrIp[i] - meanI[i] * meanP[i];
        const ai = cov / (varI[i] + eps);
        a[i] = ai; b[i] = meanP[i] - ai * meanI[i];
      }
      const ma = boxBlur(a, w, h, r), mb = boxBlur(b, w, h, r);
      for (let i = 0; i < n; i++) ma[i] = ma[i] * I[i] + mb[i];
      outs.push(ma);
    }
    return outs;
  }

  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function smoothstep(a, b, x) { const t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t); }

  function toYCC(rgba, n) {
    const R = new Float32Array(n), G = new Float32Array(n), B = new Float32Array(n);
    const Y = new Float32Array(n), Cb = new Float32Array(n), Cr = new Float32Array(n);
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const r = rgba[j], g = rgba[j + 1], b = rgba[j + 2];
      R[i] = r; G[i] = g; B[i] = b;
      Y[i] = 0.299 * r + 0.587 * g + 0.114 * b;
      Cb[i] = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
      Cr[i] = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    }
    return { R, G, B, Y, Cb, Cr };
  }

  function lumaOf(rgba, n) {
    const Y = new Float32Array(n);
    for (let i = 0, j = 0; i < n; i++, j += 4) Y[i] = 0.299 * rgba[j] + 0.587 * rgba[j + 1] + 0.114 * rgba[j + 2];
    return Y;
  }

  // ---------- свет и качество (до ретуши) ----------
  // Баланс белого и экспозиция по белому фону: фон приводится к белому, лицо осветляется так же.
  function whiteBalance(rgba, w, h, amount, info) {
    if (amount <= 0) return;
    const bw = Math.max(2, Math.round(w * 0.025)), yLim = Math.round(h * 0.6);
    const smp = [];
    const push = (x, y) => { const j = (y * w + x) * 4; smp.push(rgba[j], rgba[j + 1], rgba[j + 2]); };
    for (let y = 0; y < Math.max(2, Math.round(h * 0.025)); y += 2) for (let x = 0; x < w; x += 2) push(x, y);
    for (let y = 0; y < yLim; y += 2) for (let x = 0; x < bw; x += 2) { push(x, y); push(w - 1 - x, y); }
    const cnt = smp.length / 3;
    const ys = new Float32Array(cnt);
    for (let k = 0; k < cnt; k++) ys[k] = 0.299 * smp[3 * k] + 0.587 * smp[3 * k + 1] + 0.114 * smp[3 * k + 2];
    const sorted = Float32Array.from(ys).sort();
    const thr = sorted[Math.floor(cnt * 0.4)];
    let sr = 0, sg = 0, sb = 0, c = 0;
    for (let k = 0; k < cnt; k++) {
      const r = smp[3 * k], g = smp[3 * k + 1], b = smp[3 * k + 2];
      if (ys[k] < thr || Math.max(r, g, b) - Math.min(r, g, b) > 45) continue;
      sr += r; sg += g; sb += b; c++;
    }
    if (c < 50) return;
    sr /= c; sg /= c; sb /= c;
    if (Math.min(sr, sg, sb) < 110) { info.bgNote = 'Фон тёмный — свет по фону не выравнивался'; return; }
    const T = 247;
    const gr = Math.min(1.45, Math.max(0.85, T / sr)), gg = Math.min(1.45, Math.max(0.85, T / sg)), gb = Math.min(1.45, Math.max(0.85, T / sb));
    const lut = [new Uint8ClampedArray(256), new Uint8ClampedArray(256), new Uint8ClampedArray(256)];
    [gr, gg, gb].forEach((g, ch) => {
      const k = 1 + (g - 1) * amount;
      // мягкое плечо у белого, чтобы не выбивать светлые участки кожи
      for (let v = 0; v < 256; v++) {
        let o = v * k;
        if (o > 235) o = 235 + (255 - 235) * Math.tanh((o - 235) / 20);
        lut[ch][v] = Math.round(o);
      }
    });
    const n = w * h;
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      rgba[j] = lut[0][rgba[j]]; rgba[j + 1] = lut[1][rgba[j + 1]]; rgba[j + 2] = lut[2][rgba[j + 2]];
    }
    info.wb = [+gr.toFixed(3), +gg.toFixed(3), +gb.toFixed(3)];
  }

  // Шумоподавление: цветной шум сильно, яркостный слегка (по краям не размывает)
  function denoise(rgba, w, h, amount) {
    if (amount <= 0) return;
    const n = w * h;
    const { Y, Cb, Cr } = toYCC(rgba, n);
    const r = Math.max(2, Math.round(Math.max(w, h) / 900));
    const [Yd] = guided(Y, [Y], w, h, 1, Math.pow(4 + 4 * amount, 2));
    const [Cbd, Crd] = guided(Y, [Cb, Cr], w, h, r, Math.pow(12, 2));
    const ky = 0.6 * amount, kc = 0.9 * amount;
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const y = Y[i] + ky * (Yd[i] - Y[i]);
      const cb = Cb[i] + kc * (Cbd[i] - Cb[i]) - 128, cr = Cr[i] + kc * (Crd[i] - Cr[i]) - 128;
      rgba[j] = y + 1.402 * cr; rgba[j + 1] = y - 0.344136 * cb - 0.714136 * cr; rgba[j + 2] = y + 1.772 * cb;
    }
  }

  // ---------- маски ----------
  function skinMask(Y, Cb, Cr, R, G, B, n) {
    const m = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const ok = Cr[i] > 133 && Cr[i] < 177 && Cb[i] > 77 && Cb[i] < 128 &&
        Y[i] > 70 && R[i] > G[i] && G[i] > B[i] * 0.85;
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
    // верх лица: первая строка, с которой несколько строк подряд широкие (одиночные шумные строки не считаются)
    let y0 = -1;
    const need = Math.max(3, Math.round(h * 0.004));
    for (let y = 0; y < h - need; y++) {
      let ok = true;
      for (let k = 0; k < need; k++) if (runs[y + k] <= 0.06 * w) { ok = false; break; }
      if (ok) { y0 = y; break; }
    }
    if (y0 < 0) return null;
    let fs = 0, cx = 0, cnt = 0;
    const yEnd = Math.min(h - 1, y0 + Math.round(0.30 * h));
    for (let y = y0; y <= yEnd; y++) if (runs[y] > fs) fs = runs[y];
    for (let y = y0; y <= yEnd; y++) if (runs[y] > fs * 0.8) { cx += runCenter[y]; cnt++; }
    cx = cx / Math.max(1, cnt);
    fs = Math.max(0.12 * w, Math.min(0.7 * w, fs));
    return { y0, fs, cx };
  }

  // центры глаз: самые тёмные детали (зрачки, ресницы) слева и справа от центра лица.
  // Брови тоже тёмные, поэтому из пиков по высоте берём нижний.
  function findEyes(Y, localY, w, h, info) {
    const fs = info.fs, cx = info.cx, y0 = info.y0;
    const ya = Math.max(0, Math.round(y0 + 0.15 * fs)), yb = Math.min(h - 1, Math.round(y0 + 0.72 * fs));
    if (yb - ya < 5) return null;
    const res = [];
    const dark = i => clamp01((localY[i] - Y[i] - 45) / 30);
    for (const side of [-1, 1]) {
      const xa = Math.max(0, Math.round(side < 0 ? cx - 0.42 * fs : cx + 0.07 * fs));
      const xb = Math.min(w - 1, Math.round(side < 0 ? cx - 0.07 * fs : cx + 0.42 * fs));
      const prof = new Float32Array(yb - ya + 1);
      for (let y = ya; y <= yb; y++) { let s = 0; for (let x = xa; x <= xb; x++) s += dark(y * w + x); prof[y - ya] = s; }
      const ps = boxBlurExact(prof, prof.length, 1, Math.max(1, Math.round(fs * 0.015)));
      let mx = 0; for (const v of ps) if (v > mx) mx = v;
      if (mx < fs * 0.02) return null;
      // нижний заметный пик
      let pk = -1;
      for (let k = ps.length - 2; k >= 1; k--) if (ps[k] >= 0.2 * mx && ps[k] >= ps[k - 1] && ps[k] >= ps[k + 1]) { pk = k; break; }
      if (pk < 0) return null;
      const yc = ya + pk, yr = Math.round(0.05 * fs);
      let sw = 0, sx = 0, sy = 0;
      for (let y = Math.max(0, yc - yr); y <= Math.min(h - 1, yc + yr); y++) for (let x = xa; x <= xb; x++) {
        const v = dark(y * w + x); if (v > 0) { sw += v; sx += v * x; sy += v * y; }
      }
      if (sw <= 0) return null;
      res.push({ x: sx / sw, y: sy / sw });
    }
    const dx = Math.abs(res[1].x - res[0].x), dy = Math.abs(res[1].y - res[0].y);
    if (dx < 0.25 * fs || dx > 0.8 * fs || dy > 0.12 * fs) return null;
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
    // закрываем мелкие дыры в маске (сильно красные прыщи не проходят по цвету кожи)
    const rc = Math.max(2, fs * 0.02);
    const dil = boxBlur(skinBin, w, h, rc);
    for (let i = 0; i < n; i++) dil[i] = dil[i] > 0.12 ? 1 : 0;
    const ero = boxBlur(dil, w, h, rc);
    const closed = new Float32Array(n);
    for (let i = 0; i < n; i++) closed[i] = Math.max(skinBin[i], ero[i] > 0.88 ? 1 : 0);
    let m = boxBlur(closed, w, h, Math.max(2, fs * 0.006));
    for (let i = 0; i < n; i++) m[i] = smoothstep(0.35, 0.75, m[i]);
    m = boxBlur(m, w, h, Math.max(2, fs * 0.008));

    // защита тёмных деталей (брови, ресницы, зрачки, ноздри, губы)
    const localY = maskedBlur(Y, m, w, h, fs * 0.08);
    const prot = new Float32Array(n);
    // красноватые тёмные пятна — это прыщи, а не брови или ресницы: их не защищаем
    const localCr = maskedBlur(Cr, m, w, h, fs * 0.08);
    for (let i = 0; i < n; i++) prot[i] = clamp01((localY[i] - Y[i] - 28) / 22) * (1 - smoothstep(5, 11, Cr[i] - localCr[i]));
    const protD = boxBlur(prot, w, h, Math.max(2, fs * 0.007));
    for (let i = 0; i < n; i++) m[i] = m[i] * (1 - clamp01(protD[i] * 3)) * (1 - clamp01(bgNear[i] * 8));

    const s = o.smooth, b = o.blemish, t = o.tone, tx = o.texture;

    // защита губ: заметно «краснее» окружающей кожи на большом масштабе
    const Crq = boxBlur(Cr, w, h, Math.max(2, fs * 0.008));
    const CrBig0 = maskedBlur(Crq, m, w, h, fs * 0.12);
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
        lip[i] = smoothstep(4, 9, Crq[i] - CrBig0[i]) * (1 - smoothstep(1.0, 1.6, e));
      }
    }
    const lipD = boxBlur(lip, w, h, Math.max(2, fs * 0.012));
    for (let i = 0; i < n; i++) m[i] *= 1 - clamp01(lipD[i] * 2.2);

    // прыщи и точки: маленькие пятна темнее или краснее кожи вокруг закрашиваем кожей вокруг
    // (guided-фильтр контрастные пятна сохраняет, поэтому их убираем отдельно до него)
    if (b > 0) {
      const rl = Math.max(4, fs * 0.03);
      const Yl = maskedBlur(Y, m, w, h, rl), Crl = maskedBlur(Cr, m, w, h, rl);
      // слегка сглаженные каналы, чтобы шум и поры не считались пятнами
      const rq = Math.max(1, fs * 0.004), Yq = boxBlur(Y, w, h, rq), Crs0 = boxBlur(Cr, w, h, rq);
      const feat = boxBlur(prot, w, h, Math.max(2, fs * 0.015));
      const sp = new Float32Array(n);
      const yT = 9 - 4 * b, cT = 6 - 2.5 * b;
      for (let i = 0; i < n; i++) {
        if (m[i] < 0.05) continue;
        const sc = clamp01((Yl[i] - Yq[i] - yT) / 8) + clamp01((Crs0[i] - Crl[i] - cT) / 6) + clamp01((Yq[i] - Yl[i] - 22) / 12) * 0.6;
        sp[i] = clamp01(sc) * m[i] * (1 - clamp01(feat[i] * 4)) * (1 - clamp01(lipD[i] * 3));
      }
      const spD = boxBlur(sp, w, h, Math.max(1, fs * 0.006));
      const keepW = new Float32Array(n);
      for (let i = 0; i < n; i++) { spD[i] = clamp01(spD[i] * 2.5) * (0.4 + 0.6 * b); keepW[i] = m[i] * (1 - clamp01(spD[i] * 2)); }
      const rf = Math.max(3, fs * 0.02);
      const Yf = maskedBlur(Y, keepW, w, h, rf), Cbf = maskedBlur(Cb, keepW, w, h, rf), Crf = maskedBlur(Cr, keepW, w, h, rf);
      let cnt = 0;
      for (let i = 0; i < n; i++) {
        const k = spD[i];
        if (k <= 0.01) continue;
        cnt++;
        Y[i] += (Yf[i] - Y[i]) * k; Cb[i] += (Cbf[i] - Cb[i]) * k; Cr[i] += (Crf[i] - Cr[i]) * k;
      }
      info.spots = cnt;
    }

    const r = Math.max(3, Math.round(fs * 0.022));
    const eps = Math.pow(10 + 28 * s, 2);
    const [Ys, Cbs, Crs] = guided(Y, [Y, Cb, Cr], w, h, r, eps);

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

    // мешки и круги под глазами: тёмное подтягиваем к окружающей коже,
    // светлый валик мешка и тень складки сглаживаем к среднему
    const eo = o.eyes;
    let eyeW = null;
    if (eo > 0) {
      const eyes = findEyes(Y, localY, w, h, info);
      info.eyes = eyes;
      if (eyes) {
        const rB = fs * 0.16;
        const YB = maskedBlur(Yp, m, w, h, rB);
        const CbB = maskedBlur(Cbp, m, w, h, rB), CrB = maskedBlur(Crp, m, w, h, rB);
        const YM = maskedBlur(Yp, m, w, h, Math.max(3, fs * 0.03));
        eyeW = new Float32Array(n);
        const sx = 0.15 * fs, sy = 0.06 * fs;
        for (const e of eyes) {
          const ecx = e.x, ecy = e.y + 0.095 * fs;
          const xa = Math.max(0, Math.floor(ecx - 3 * sx)), xb = Math.min(w - 1, Math.ceil(ecx + 3 * sx));
          const ya = Math.max(0, Math.floor(ecy - 3 * sy)), yb = Math.min(h - 1, Math.ceil(ecy + 3 * sy));
          for (let y = ya; y <= yb; y++) for (let x = xa; x <= xb; x++) {
            const i = y * w + x;
            const dx = (x - ecx) / sx, dy = (y - ecy) / sy;
            const wg = Math.exp(-(dx * dx + dy * dy) / 2) * Math.min(1, eo * 1.4);
            if (wg > eyeW[i]) eyeW[i] = wg;
            const lift = Math.max(0, YB[i] - Yp[i]);
            Yp[i] += wg * 0.95 * lift;
            Yp[i] += wg * 0.6 * (YM[i] - Yp[i]);           // рельеф мешка
            Cbp[i] += wg * 0.8 * (CbB[i] - Cbp[i]);
            Crp[i] += wg * 0.6 * (CrB[i] - Crp[i]);
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
    // под глазами кожа часто выпадает из маски (тени) — добавляем зону глаз в маску
    if (eyeW) {
      const ew = boxBlur(eyeW, w, h, Math.max(2, fs * 0.01));
      for (let i = 0; i < n; i++) {
        const add = ew[i] * (1 - clamp01(protD[i] * 3)) * (1 - clamp01(bgNear[i] * 8));
        if (add > m[i]) m[i] = add;
      }
    }
    return { Yp, Cbp, Crp, mask: m };
  }

  // ---------- выразительность и резкость ----------
  // clarity: локальный контраст (глаза, брови, губы, волосы, одежда); на коже слабо, чтобы не вернуть неровности
  function expressive(rgba, w, h, skin, o, info) {
    const cl = o.clarity, sh = o.quality;
    if (cl <= 0 && sh <= 0) return;
    const n = w * h, fs = info.fs || Math.max(w, h) * 0.3;
    const Y = lumaOf(rgba, n);
    const Yl = cl > 0 ? boxBlur(boxBlur(Y, w, h, Math.max(3, fs * 0.03)), w, h, Math.max(3, fs * 0.03)) : null;
    const Ys = sh > 0 ? boxBlur(Y, w, h, Math.max(1, Math.round(Math.max(w, h) / 1600))) : null;
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const sk = skin ? skin[i] : 0;
      let d = 0;
      if (Yl) { const v = Y[i] - Yl[i]; d += cl * 0.9 * (1 - 0.8 * sk) * 22 * Math.tanh(v / 22); }
      if (Ys) { const v = Y[i] - Ys[i]; d += sh * 1.1 * (1 - 0.85 * sk) * 14 * Math.tanh(v / 14); }
      // белый фон не трогаем
      if (Y[i] > 238) d *= clamp01((250 - Y[i]) / 12);
      if (d === 0) continue;
      rgba[j] += d; rgba[j + 1] += d; rgba[j + 2] += d;
    }
    // чуть насыщеннее цвет глаз, губ и одежды (не кожи)
    if (cl > 0) {
      const k = 0.12 * cl;
      for (let i = 0, j = 0; i < n; i++, j += 4) {
        const kk = k * (1 - (skin ? skin[i] : 0));
        if (kk <= 0) continue;
        const y = 0.299 * rgba[j] + 0.587 * rgba[j + 1] + 0.114 * rgba[j + 2];
        rgba[j] = y + (rgba[j] - y) * (1 + kk); rgba[j + 1] = y + (rgba[j + 1] - y) * (1 + kk); rgba[j + 2] = y + (rgba[j + 2] - y) * (1 + kk);
      }
    }
  }

  // ---------- белый фон ----------
  function whitenBackground(rgba, w, h, amount, info) {
    if (amount <= 0) return;
    const n = w * h;
    const yc = toYCC(rgba, n), rq = Math.max(1, Math.round(Math.max(w, h) / 800));
    const Y = boxBlur(yc.Y, w, h, rq), Cb = boxBlur(yc.Cb, w, h, rq), Cr = boxBlur(yc.Cr, w, h, rq);
    // ниже подбородка (одежда, белая рубашка) берём только почти белое, чтобы не стереть складки
    const yChin = info.y0 != null ? Math.min(h - 1, Math.round(info.y0 + 1.25 * info.fs)) : h;
    const ok = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      const lowP = i >= yChin * w;
      ok[i] = (Y[i] > (lowP ? 228 : 200) && Math.abs(Cb[i] - 128) < (lowP ? 8 : 12) && Math.abs(Cr[i] - 128) < (lowP ? 8 : 12)) ? 1 : 0;
    }
    const yMax = h - 1;
    const lab = new Uint8Array(n), stack = new Int32Array(n);
    let sp = 0;
    const seed = i => { if (ok[i] && !lab[i]) { lab[i] = 1; stack[sp++] = i; } };
    for (let x = 0; x < w; x++) seed(x);
    for (let y = 0; y <= yMax; y++) { seed(y * w); seed(y * w + w - 1); }
    while (sp > 0) {
      const i = stack[--sp], x = i % w, y = (i - x) / w;
      if (x > 0) seed(i - 1);
      if (x < w - 1) seed(i + 1);
      if (y > 0) seed(i - w);
      if (y < yMax) seed(i + w);
    }
    const mf = new Float32Array(n);
    for (let i = 0; i < n; i++) mf[i] = lab[i];
    // отступ от силуэта на пару пикселей, чтобы не съесть кончики волос
    const er = Math.max(1, Math.round(Math.max(w, h) / 1200));
    const md = boxBlur(mf, w, h, er);
    for (let i = 0; i < n; i++) mf[i] = smoothstep(0.75, 1, md[i]);
    const ms = boxBlur(mf, w, h, er);
    let cnt = 0;
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const k = ms[i] * Math.min(1, amount * 1.6);
      if (k <= 0.001) continue;
      cnt++;
      rgba[j] += (255 - rgba[j]) * k; rgba[j + 1] += (255 - rgba[j + 1]) * k; rgba[j + 2] += (255 - rgba[j + 2]) * k;
    }
    info.bgPixels = cnt;
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
    for (let i = 0; i < n; i++) bg[i] = (Y[i] > 215 && Math.abs(Cb[i] - 128) < 12 && Math.abs(Cr[i] - 128) < 12) ? 1 : 0;
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
    // мягкую кромку волос (полутона к фону) не считаем волосами, иначе после наращивания
    // она остаётся светлой линией внутри причёски
    const hair0 = new Float32Array(n);
    for (let i = 0; i < n; i++) hair0[i] = lab[i];
    const hb = boxBlur(hair0, w, h, Math.max(2, fs * 0.008));
    const hair = new Float32Array(n);
    for (let i = 0; i < n; i++) hair[i] = lab[i] && hb[i] > 0.97 ? 1 : 0;

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
        const rx0 = x - cx, ry0 = y - cy;
        const ex = rx0 / (0.60 * fs), ey = ry0 / (0.72 * fs);
        const wFace = smoothstep(0.92, 1.2, Math.sqrt(ex * ex + ey * ey));
        if (wFace <= 0) continue;
        const wSkin = 1 - clamp01(skinNear[i] * 2.5);
        const D = maxShift * wFace * wSkin * vFade;
        if (t >= D) continue;
        if (y + gpx >= h || y - gpx < 0) continue;
        const gx = dsm[i + gpx] - dsm[i - gpx], gy = dsm[i + gpx * w] - dsm[i - gpx * w];
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
  const DEFAULTS = { smooth: 55, blemish: 70, tone: 60, fresh: 30, texture: 50, eyes: 60, hair: 25, clarity: 35, quality: 40, bg: 60 };

  function run(rgba, w, h, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    for (const k of Object.keys(DEFAULTS)) o[k] = clamp01(o[k] / 100);
    const n = w * h;
    const info = {};

    // 1. свет по белому фону и шумоподавление — на копии исходника
    const base = new Uint8ClampedArray(rgba);
    whiteBalance(base, w, h, o.bg, info);
    denoise(base, w, h, o.quality);

    const { R, G, B, Y, Cb, Cr } = toYCC(base, n);
    const skinBin = skinMask(Y, Cb, Cr, R, G, B, n);
    const geo = faceGeometry(skinBin, w, h);
    if (!geo) { info.error = 'Лицо не найдено'; return { data: base, info }; }
    Object.assign(info, geo);

    // 2. кожа
    const planes = { Y, Cb, Cr, skinBin };
    const sk = retouchSkin(planes, w, h, o, info);
    const out = new Uint8ClampedArray(rgba.length);
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const wgt = sk.mask[i];
      const y = sk.Yp[i], cb = sk.Cbp[i] - 128, cr = sk.Crp[i] - 128;
      const r = y + 1.402 * cr, g = y - 0.344136 * cb - 0.714136 * cr, b = y + 1.772 * cb;
      out[j] = base[j] * (1 - wgt) + r * wgt;
      out[j + 1] = base[j + 1] * (1 - wgt) + g * wgt;
      out[j + 2] = base[j + 2] * (1 - wgt) + b * wgt;
      out[j + 3] = base[j + 3];
    }
    // 3. выразительность и резкость
    expressive(out, w, h, sk.mask, o, info);
    // 4. волосы: маски по плоскостям до ретуши, сдвигаем пиксели результата
    const hairOut = hairVolume(out, planes, w, h, o, info);
    const res = hairOut || out;
    // 5. фон добеливаем в самом конце
    whitenBackground(res, w, h, o.bg, info);
    return { data: res, info };
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

  root.Retouch = { run, heal, boxBlur, guided, DEFAULTS };
  if (typeof module !== 'undefined') module.exports = root.Retouch;
})(typeof self !== 'undefined' ? self : typeof window !== 'undefined' ? window : globalThis);
