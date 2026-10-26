/* Фоновый поток ретуши: страница не зависает, пока считается фото. */
importScripts('core.js');
self.onmessage = function (e) {
  var d = e.data;
  try {
    var res = Retouch.run(new Uint8ClampedArray(d.buf), d.w, d.h, d.opts);
    var i = res.info;
    self.postMessage({ id: d.id, buf: res.data.buffer, info: { error: i.error, hairNote: i.hairNote, bgNote: i.bgNote, eyes: !!i.eyes } }, [res.data.buffer]);
  } catch (err) {
    self.postMessage({ id: d.id, fail: String((err && err.message) || err) });
  }
};
