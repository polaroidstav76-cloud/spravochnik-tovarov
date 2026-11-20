/* Exact frame geometry and rendering from foto-26-site/src/lib/polaroidFrames.ts. */
(()=>{
// Рамки полароида: перенесены из «Приложения полароид» (шаблоны группы «Полароиды»).
// Каждая рамка — лист 10×15 см при 300 точках на дюйм: белый лист, окошко для фото и линии реза.
// На листе 6×9 два полароида: клиент видит и оплачивает каждый отдельно, сотрудник печатает по два на листе.
// Рисует только браузер (canvas): клиент видит ровно то, что уйдёт в печать.
const PRINT_DPI = 300;
const GUIDE = 2; // толщина линии реза, точек (0,17 мм)
const PORTRAIT = { w: 1181, h: 1772 };
// Порядок — как у кнопок размеров на сайте
const FRAMES = [
    {
        key: "6x9", name: "6×9 (2 шт. на листе)", w: 1772, h: 1181, rows: [86, 1065.5], cols: [150, 803, 956, 1609],
        slots: [{ win: [202, 139, 551, 709], cut: [150, 86, 653, 979.5] }, { win: [1007, 139, 553, 709], cut: [956, 86, 653, 979.5] }],
    },
    { key: "8x8", name: "8×8", ...PORTRAIT, rows: [188.5, 1086.5], cols: [141.5, 1039.5], slots: [{ win: [254, 301, 674, 674], cut: [141.5, 188.5, 898, 898] }] },
    { key: "10x10", name: "10×10", ...PORTRAIT, rows: [1156.5], cols: [], slots: [{ win: [95, 107, 977, 775], cut: [0, 0, 1181, 1156.5] }] },
    { key: "10x12", name: "10×12", ...PORTRAIT, rows: [1334.5], cols: [], slots: [{ win: [95, 119, 985, 924], cut: [0, 0, 1181, 1334.5] }] },
    { key: "10x15", name: "10×15", ...PORTRAIT, rows: [], cols: [], slots: [{ win: [107, 107, 967, 1345], cut: [0, 0, 1181, 1772] }] },
    { key: "7x10", name: "7×10 (3 мм)", ...PORTRAIT, rows: [253.5, 1335.5], cols: [209.5, 970.5], slots: [{ win: [245, 288, 691, 1012], cut: [209.5, 253.5, 761, 1082] }] },
    { key: "10x15-3mm", name: "10×15 (3 мм)", ...PORTRAIT, rows: [], cols: [], slots: [{ win: [84, 96, 1001, 1556], cut: [0, 0, 1181, 1772] }] },
];
const frameByKey = (key) => FRAMES.find((f) => f.key === key);
// Рамка формата: выбранная в админке, иначе угадываем по названию («7х10») или размеру формата
function frameFor(f) {
    const chosen = frameByKey(f.frame);
    if (chosen)
        return chosen;
    const label = f.label.toLowerCase().replace(/[хx×*]/g, "x");
    const m = label.match(/(\d+)\s*x\s*(\d+)/);
    const dims = m ? [Number(m[1]), Number(m[2])] : [Math.round(f.w), Math.round(f.h)];
    const [a, b] = [Math.min(...dims), Math.max(...dims)];
    const key = `${a}x${b}`;
    if (key === "10x15" && /3\s*(мм|mm)/.test(label))
        return frameByKey("10x15-3mm");
    return frameByKey(key) ?? frameByKey("10x15");
}
// Размер фото в окошке (в точках листа) и сдвиг: без полей фото не открывает белые края;
// с полями фото можно уменьшить (до FIELDS_MIN_ZOOM) и двигать, пока край фото не дойдёт до края окошка
const FIELDS_MIN_ZOOM = 0.4;
function fit(win, p) {
    const [, , w, h] = win;
    const [rw, rh] = p.rot % 2 ? [p.ih, p.iw] : [p.iw, p.ih];
    const s = p.mode === "none" ? Math.max(w / rw, h / rh) * Math.max(1, p.zoom) : Math.min(w / rw, h / rh) * Math.max(FIELDS_MIN_ZOOM, p.zoom);
    const mx = Math.abs(rw * s - w) / 2 / w, my = Math.abs(rh * s - h) / 2 / h;
    return { s, ox: Math.max(-mx, Math.min(mx, p.ox)), oy: Math.max(-my, Math.min(my, p.oy)) };
}
function clampPlacement(win, p) {
    const { ox, oy } = fit(win, p);
    return { zoom: p.zoom, ox, oy, rot: p.rot, mode: p.mode };
}
// Сколько точек фото нужно для печати этого окошка (по длинной стороне снимка)
function needPx(win, p) {
    return Math.max(p.iw, p.ih) * fit(win, p).s;
}
function drawPhoto(c, win, p) {
    const [x, y, w, h] = win;
    const { s, ox, oy } = fit(win, p);
    c.save();
    c.beginPath();
    c.rect(x, y, w, h);
    c.clip();
    if (p.mode === "blur")
        drawBlur(c, win, p);
    c.translate(x + w / 2 + ox * w, y + h / 2 + oy * h);
    c.rotate((p.rot * Math.PI) / 2);
    c.imageSmoothingQuality = "high";
    c.drawImage(p.img, (-p.iw * s) / 2, (-p.ih * s) / 2, p.iw * s, p.ih * s);
    c.restore();
}
// Размытые поля: то же фото, растянутое на всё окошко и размытое (через сильное уменьшение — работает во всех браузерах)
function drawBlur(c, win, p) {
    const [x, y, w, h] = win;
    const small = document.createElement("canvas");
    small.width = Math.max(1, Math.round(w / 40));
    small.height = Math.max(1, Math.round(h / 40));
    const sc = small.getContext("2d");
    const [rw, rh] = p.rot % 2 ? [p.ih, p.iw] : [p.iw, p.ih];
    const s = Math.max(small.width / rw, small.height / rh);
    sc.translate(small.width / 2, small.height / 2);
    sc.rotate((p.rot * Math.PI) / 2);
    sc.drawImage(p.img, (-p.iw * s) / 2, (-p.ih * s) / 2, p.iw * s, p.ih * s);
    c.save();
    c.imageSmoothingEnabled = true;
    c.imageSmoothingQuality = "high";
    c.drawImage(small, x - w * 0.05, y - h * 0.05, w * 1.1, h * 1.1);
    c.fillStyle = "rgba(255,255,255,0.12)";
    c.fillRect(x, y, w, h);
    c.restore();
}
// Надпись на нижнем поле полароида: шрифты с кириллицей, в основном каллиграфия (подключаются в PolaroidOrder.tsx)
const CAPTION_FONTS = [
    { key: "marck", name: "Marck Script", css: "400 1px 'Marck Script'" },
    { key: "great-vibes", name: "Great Vibes", css: "400 1px 'Great Vibes'" },
    { key: "bad-script", name: "Bad Script", css: "400 1px 'Bad Script'" },
    { key: "comforter", name: "Comforter", css: "400 1px 'Comforter'" },
    { key: "comforter-brush", name: "Comforter Brush", css: "400 1px 'Comforter Brush'" },
    { key: "caveat", name: "Caveat", css: "400 1px 'Caveat'" },
    { key: "lobster", name: "Lobster", css: "400 1px 'Lobster'" },
    { key: "pacifico", name: "Pacifico", css: "400 1px 'Pacifico'" },
    { key: "lora", name: "Lora курсив", css: "italic 400 1px 'Lora'" },
    { key: "neucha", name: "Neucha", css: "400 1px 'Neucha'" },
    { key: "amatic", name: "Amatic SC", css: "700 1px 'Amatic SC'" },
    { key: "kurale", name: "Kurale", css: "400 1px 'Kurale'" },
    { key: "poiret", name: "Poiret One", css: "400 1px 'Poiret One'" },
    { key: "yeseva", name: "Yeseva One", css: "400 1px 'Yeseva One'" },
];
const fontCss = (key, px) => (CAPTION_FONTS.find((f) => f.key === key) ?? CAPTION_FONTS[0]).css.replace("1px", `${Math.round(px)}px`);
const fontLoadCss = (key) => fontCss(key, 40);
// Место под надпись: нижнее поле между окошком и линией реза. У узкого поля (7×10) надписи нет.
const MIN_CAPTION = 90; // точек, ≈ 7,6 мм
const captionBox = (slot) => {
    const top = slot.win[1] + slot.win[3], bottom = slot.cut[1] + slot.cut[3];
    return { x: slot.cut[0] + slot.cut[2] / 2, y: (top + bottom) / 2, w: slot.cut[2] * 0.86, h: bottom - top };
};
const captionFits = (frame) => captionBox(frame.slots[0]).h >= MIN_CAPTION;
function drawCaption(c, slot, cap) {
    const text = cap?.text.trim();
    if (!cap || !text)
        return;
    const b = captionBox(slot);
    if (b.h < MIN_CAPTION)
        return;
    let px = Math.min(b.h * 0.5, 150);
    c.font = fontCss(cap.font, px);
    const tw = c.measureText(text).width;
    if (tw > b.w) {
        px *= b.w / tw;
        c.font = fontCss(cap.font, px);
    }
    c.fillStyle = cap.color;
    c.textAlign = "center";
    c.textBaseline = "middle";
    c.fillText(text, b.x, b.y);
}
function blank(c, win) {
    const [x, y, w, h] = win;
    c.fillStyle = "#e9e7e1";
    c.fillRect(x, y, w, h);
}
// Один полароид для клиента: только сам полароид (по линиям реза), без листа
function renderPolaroid(canvas, frame, photo, caption, widthPx) {
    const { win, cut } = frame.slots[0];
    const k = widthPx / cut[2];
    canvas.width = Math.round(widthPx);
    canvas.height = Math.round(cut[3] * k);
    const c = canvas.getContext("2d");
    c.setTransform(k, 0, 0, k, -cut[0] * k, -cut[1] * k);
    c.fillStyle = "#fff";
    c.fillRect(cut[0], cut[1], cut[2], cut[3]);
    if (photo)
        drawPhoto(c, win, photo);
    else
        blank(c, win);
    drawCaption(c, frame.slots[0], caption);
}
// Лист для печати: полароиды в окошках и чёрные линии реза через весь лист
function renderSheet(canvas, frame, photos) {
    canvas.width = frame.w;
    canvas.height = frame.h;
    const c = canvas.getContext("2d");
    c.fillStyle = "#fff";
    c.fillRect(0, 0, frame.w, frame.h);
    frame.slots.forEach((s, i) => {
        const p = photos[i];
        if (!p)
            return;
        drawPhoto(c, s.win, p.photo);
        drawCaption(c, s, p.caption);
    });
    c.fillStyle = "#000";
    for (const y of frame.rows)
        c.fillRect(0, Math.round(y - GUIDE / 2), frame.w, GUIDE);
    for (const x of frame.cols)
        c.fillRect(Math.round(x - GUIDE / 2), 0, GUIDE, frame.h);
}

PhotoLinks.polaroid={FRAMES,renderPolaroid,clampPlacement,needPx};
})();
