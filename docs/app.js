'use strict';

/* ProCam Reel Master — browser edition.
 * Records camera + mic locally with MediaRecorder. No uploads, no server. */

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];

const ASPECTS = {
  '9:16': { w: 1080, h: 1920 },
  '16:9': { w: 1920, h: 1080 },
  '1:1': { w: 1080, h: 1080 },
  '4:5': { w: 1080, h: 1350 },
};

const MIMES = [
  'video/mp4;codecs=avc1.640028,mp4a.40.2',
  'video/mp4;codecs=avc1.42E01E,mp4a.40.2',
  'video/mp4',
  'video/webm;codecs=vp9,opus',
  'video/webm;codecs=vp8,opus',
  'video/webm',
];

const VIDEO_BPS = 18_000_000;
const AUDIO_BPS = 192_000;

const state = {
  aspect: '9:16',
  fps: 30,
  uhd: false,
  facing: 'environment',
  torch: false,
  zoom: 1,
  grid: true,
  promptOn: true,
  promptPlaying: false,
  promptSpeed: 26,
  promptSize: 24,
  promptOpacity: 0.8,
  script: 'Paste your script here.\n\nTap Edit to change it.',
  micId: '',
  recording: false,
  ready: false,
};

const el = {
  stageWrap: $('#stageWrap'),
  stage: $('#stage'),
  canvas: $('#stageCanvas'),
  ctx: $('#stageCanvas').getContext('2d', { alpha: false }),
  grid: $('#grid'),
  prompter: $('#prompter'),
  promptHead: $('#prompterHead'),
  promptViewport: $('#promptViewport'),
  promptText: $('#promptText'),
  promptPlay: $('#promptPlay'),
  recBadge: $('#recBadge'),
  recTime: $('#recTime'),
  qualityBadge: $('#qualityBadge'),
  gate: $('#permGate'),
  topBar: $('#topBar'),
  bottomBar: $('#bottomBar'),
  recBtn: $('#recBtn'),
  micBtn: $('#micBtn'),
  galleryBtn: $('#galleryBtn'),
  lastThumb: $('#lastThumb'),
  qualityBtn: $('#qualityBtn'),
  gridBtn: $('#gridBtn'),
  torchBtn: $('#torchBtn'),
  sheet: $('#sheet'),
  sheetBody: $('#sheetBody'),
  toast: $('#toast'),
  gallery: $('#gallery'),
  galleryGrid: $('#galleryGrid'),
  galleryMeta: $('#galleryMeta'),
  galleryEmpty: $('#galleryEmpty'),
  editor: $('#editor'),
  scriptArea: $('#scriptArea'),
};

const video = document.createElement('video');
video.playsInline = true;
video.muted = true;
video.autoplay = true;
video.setAttribute('playsinline', '');

let stream = null;
let micStream = null;
let audioCtx = null;
let audioDest = null;
let audioTrack = null;
let recorder = null;
let chunks = [];
let startedAt = 0;
let timerId = 0;
let rafId = 0;
let lastDraw = 0;
let wakeLock = null;
let promptOffset = 0;
let promptLastT = 0;
let lastObjectUrl = null;

/* ---------------- utils ---------------- */

const fmtSize = (b) => {
  if (!b) return '0 MB';
  const mb = b / (1024 * 1024);
  return mb < 1000 ? `${mb.toFixed(1)} MB` : `${(mb / 1024).toFixed(2)} GB`;
};

const fmtDur = (s) => {
  s = Math.max(0, Math.round(s));
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return `${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
};

let toastTimer = 0;
function toast(msg) {
  el.toast.textContent = msg;
  el.toast.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.toast.classList.add('hidden'), 2400);
}

function saveSettings() {
  try {
    localStorage.setItem('procam-web', JSON.stringify({
      aspect: state.aspect,
      fps: state.fps,
      uhd: state.uhd,
      grid: state.grid,
      promptOn: state.promptOn,
      promptSpeed: state.promptSpeed,
      promptSize: state.promptSize,
      promptOpacity: state.promptOpacity,
      script: state.script,
      micId: state.micId,
    }));
  } catch { /* private mode */ }
}

function loadSettings() {
  try {
    const raw = localStorage.getItem('procam-web');
    if (!raw) return;
    const s = JSON.parse(raw);
    Object.assign(state, {
      aspect: ASPECTS[s.aspect] ? s.aspect : state.aspect,
      fps: s.fps === 60 ? 60 : 30,
      uhd: !!s.uhd,
      grid: s.grid !== false,
      promptOn: s.promptOn !== false,
      promptSpeed: Number(s.promptSpeed) || 26,
      promptSize: Number(s.promptSize) || 24,
      promptOpacity: Number(s.promptOpacity) || 0.8,
      script: typeof s.script === 'string' ? s.script : state.script,
      micId: typeof s.micId === 'string' ? s.micId : '',
    });
  } catch { /* ignore */ }
}

/* ---------------- stage ---------------- */

function canvasSize() {
  return ASPECTS[state.aspect] || ASPECTS['9:16'];
}

function applyCanvasSize() {
  const { w, h } = canvasSize();
  if (el.canvas.width !== w) el.canvas.width = w;
  if (el.canvas.height !== h) el.canvas.height = h;
}

function layoutStage() {
  const box = el.stageWrap.getBoundingClientRect();
  const { w, h } = canvasSize();
  const scale = Math.min(box.width / w, box.height / h);
  el.stage.style.width = `${Math.floor(w * scale)}px`;
  el.stage.style.height = `${Math.floor(h * scale)}px`;
}

function drawFrame() {
  const vw = video.videoWidth;
  const vh = video.videoHeight;
  if (!vw || !vh) return;

  const cw = el.canvas.width;
  const ch = el.canvas.height;
  const target = cw / ch;
  const srcRatio = vw / vh;

  let sw;
  let sh;
  if (srcRatio > target) {
    sh = vh;
    sw = sh * target;
  } else {
    sw = vw;
    sh = sw / target;
  }

  const z = Math.max(1, state.zoom);
  sw /= z;
  sh /= z;

  const sx = (vw - sw) / 2;
  const sy = (vh - sh) / 2;

  const ctx = el.ctx;
  ctx.save();
  if (state.facing === 'user') {
    ctx.translate(cw, 0);
    ctx.scale(-1, 1);
  }
  ctx.drawImage(video, sx, sy, sw, sh, 0, 0, cw, ch);
  ctx.restore();
}

function loop(ts) {
  rafId = requestAnimationFrame(loop);
  if (document.hidden) return;
  const minGap = 1000 / (state.fps + 4);
  if (ts - lastDraw < minGap) return;
  lastDraw = ts;
  drawFrame();
}

/* ---------------- camera ---------------- */

function videoConstraints() {
  const w = state.uhd ? 3840 : 1920;
  const h = state.uhd ? 2160 : 1080;
  return {
    facingMode: { ideal: state.facing },
    width: { ideal: w },
    height: { ideal: h },
    frameRate: { ideal: state.fps },
  };
}

async function startCamera() {
  if (!navigator.mediaDevices?.getUserMedia) {
    toast('Camera needs HTTPS (or localhost) in a modern browser');
    return;
  }
  try {
    stream?.getTracks().forEach((t) => t.stop());
    stream = await navigator.mediaDevices.getUserMedia({
      video: videoConstraints(),
      audio: false,
    });
    video.srcObject = stream;
    await video.play().catch(() => {});
    await startMic(state.micId);
    state.ready = true;
    el.gate.classList.add('hidden');
    el.topBar.classList.remove('hidden');
    el.bottomBar.classList.remove('hidden');
    layoutStage();
    applyCanvasSize();
    updateButtons();
    await refreshMics();
    await updateQualityLabel();
    updateTorchButton();
    if (!rafId) rafId = requestAnimationFrame(loop);
  } catch (err) {
    console.error(err);
    toast(err?.name === 'NotAllowedError'
      ? 'Camera permission denied — allow it in the browser settings'
      : 'Could not start camera');
  }
}

async function restartVideoTrack() {
  if (!stream) return;
  try {
    const old = stream.getVideoTracks()[0];
    old?.stop();
    if (old) stream.removeTrack(old);
    const fresh = await navigator.mediaDevices.getUserMedia({
      video: videoConstraints(),
      audio: false,
    });
    stream.addTrack(fresh.getVideoTracks()[0]);
    video.srcObject = stream;
    await video.play().catch(() => {});
    updateTorchButton();
    await updateQualityLabel();
  } catch (err) {
    console.error(err);
    toast('Could not switch camera');
  }
}

async function updateQualityLabel() {
  const track = stream?.getVideoTracks?.()[0];
  if (!track) return;
  const s = track.getSettings?.() || {};
  const h = s.height || 0;
  el.qualityBadge.textContent = h >= 2000 ? `4K · ${s.width}×${s.height}` : `${s.width || '?'}×${h || '?'}`;
  el.qualityBadge.classList.remove('hidden');
  return s;
}

function updateTorchButton() {
  const track = stream?.getVideoTracks?.()[0];
  const caps = track?.getCapabilities?.() || {};
  const supported = !!caps.torch;
  el.torchBtn.disabled = !supported;
  el.torchBtn.classList.toggle('active', state.torch && supported);
  if (!supported) state.torch = false;
}

async function toggleTorch() {
  const track = stream?.getVideoTracks?.()[0];
  if (!track) return;
  try {
    state.torch = !state.torch;
    await track.applyConstraints({ advanced: [{ torch: state.torch }] });
    updateTorchButton();
  } catch {
    state.torch = false;
    toast('Flash is not available on this camera');
  }
}

/* ---------------- microphone ---------------- */

async function startMic(deviceId) {
  stopMic();
  try {
    const constraints = {
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
    };
    micStream = await navigator.mediaDevices.getUserMedia({ audio: constraints, video: false });
  } catch {
    micStream = null;
    return;
  }

  try {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === 'suspended') await audioCtx.resume();
    const src = audioCtx.createMediaStreamSource(micStream);

    const highpass = audioCtx.createBiquadFilter();
    highpass.type = 'highpass';
    highpass.frequency.value = 90;

    const lowpass = audioCtx.createBiquadFilter();
    lowpass.type = 'lowpass';
    lowpass.frequency.value = 12000;

    const comp = audioCtx.createDynamicsCompressor();
    comp.threshold.value = -24;
    comp.knee.value = 24;
    comp.ratio.value = 3;
    comp.attack.value = 0.003;
    comp.release.value = 0.25;

    audioDest = audioCtx.createMediaStreamDestination();
    src.connect(highpass);
    highpass.connect(lowpass);
    lowpass.connect(comp);
    comp.connect(audioDest);
    audioTrack = audioDest.stream.getAudioTracks()[0] || null;
  } catch (err) {
    console.warn('audio graph failed', err);
    audioTrack = micStream?.getAudioTracks?.()[0] || null;
  }
}

function stopMic() {
  micStream?.getTracks().forEach((t) => t.stop());
  micStream = null;
  audioTrack = null;
  try { audioDest?.stream.getTracks().forEach((t) => t.stop()); } catch { /* noop */ }
  audioDest = null;
  if (audioCtx) {
    audioCtx.close().catch(() => {});
    audioCtx = null;
  }
}

async function refreshMics() {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const mics = devices.filter((d) => d.kind === 'audioinput');
    if (!state.micId && mics[0]) state.micId = mics[0].deviceId;
    return mics;
  } catch {
    return [];
  }
}

function micIconFor(device) {
  const label = (device.label || '').toLowerCase();
  if (label.includes('bluetooth') || label.includes('bt ')) return 'Bluetooth';
  if (label.includes('usb')) return 'USB';
  if (label.includes('headset') || label.includes('wired')) return 'Wired';
  return 'Built-in';
}

async function openMicSheet() {
  const mics = await refreshMics();
  const rows = mics.length
    ? mics.map((m) => `
      <button class="list-item ${m.deviceId === state.micId ? 'active' : ''}" data-mic="${encodeURIComponent(m.deviceId)}">
        <svg class="ic"><use href="#i-mic"/></svg>
        <span>
          <span class="li-title">${m.label || 'Microphone'}</span>
          <span class="li-sub">${micIconFor(m)}</span>
        </span>
        ${m.deviceId === state.micId ? '<span class="li-check">✓</span>' : ''}
      </button>`).join('')
    : '<p class="sub">No microphone found.</p>';

  openSheet(`
    <h2>Microphone source</h2>
    <p class="sub">Built-in, wired, USB and Bluetooth mics appear here if the OS exposes them. A high-pass + low-pass + compressor chain is applied while recording.</p>
    ${rows}
    <p class="sub" style="margin-top:14px">Web browsers cannot route Bluetooth SCO directly; use the system mic picker if your phone exposes it.</p>
  `);

  $$('#sheetBody [data-mic]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const id = decodeURIComponent(btn.dataset.mic);
      state.micId = id;
      saveSettings();
      closeSheet();
      await startMic(id);
      toast('Microphone switched');
    });
  });
}

/* ---------------- recording ---------------- */

function pickMime() {
  if (typeof MediaRecorder === 'undefined') return '';
  return MIMES.find((m) => MediaRecorder.isTypeSupported(m)) || '';
}

function startTimer() {
  startedAt = performance.now();
  clearInterval(timerId);
  timerId = setInterval(() => {
    el.recTime.textContent = fmtDur((performance.now() - startedAt) / 1000);
  }, 250);
}

async function startRecording() {
  if (!stream || state.recording) return;
  if (typeof MediaRecorder === 'undefined' || !el.canvas.captureStream) {
    toast('This browser cannot record video. Try Chrome, Edge or Safari.');
    return;
  }

  applyCanvasSize();
  try { await navigator.storage?.persist?.(); } catch { /* noop */ }

  const canvasStream = el.canvas.captureStream(state.fps);
  if (audioTrack) canvasStream.addTrack(audioTrack);
  else toast('Recording without audio — mic unavailable');

  const mime = pickMime();
  const options = { videoBitsPerSecond: VIDEO_BPS, audioBitsPerSecond: AUDIO_BPS };
  if (mime) options.mimeType = mime;

  try {
    recorder = new MediaRecorder(canvasStream, options);
  } catch {
    recorder = new MediaRecorder(canvasStream);
  }

  chunks = [];
  recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
  recorder.onstop = finalizeRecording;
  recorder.onerror = () => toast('Recorder error — take discarded');
  recorder.start(1000);

  state.recording = true;
  document.body.classList.add('recording');
  el.recBadge.classList.remove('hidden');
  el.recTime.textContent = '00:00';
  startTimer();
  promptPlay(true);
  lockUi(true);

  try {
    wakeLock = await navigator.wakeLock?.request?.('screen');
  } catch { /* noop */ }
}

function stopRecording() {
  if (!state.recording || !recorder) return;
  state.recording = false;
  document.body.classList.remove('recording');
  el.recBadge.classList.add('hidden');
  clearInterval(timerId);
  promptPlay(false);
  lockUi(false);
  try { recorder.stop(); } catch { /* noop */ }
  try { wakeLock?.release?.(); } catch { /* noop */ }
  wakeLock = null;
}

async function finalizeRecording() {
  const duration = startedAt ? (performance.now() - startedAt) / 1000 : 0;
  const type = recorder?.mimeType || chunks[0]?.type || 'video/webm';
  const blob = new Blob(chunks, { type });
  chunks = [];
  recorder = null;

  if (!blob.size) {
    toast('Recording was empty');
    return;
  }

  const { w, h } = canvasSize();
  const isMp4 = type.includes('mp4');
  const clip = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
    name: `REEL_${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.${isMp4 ? 'mp4' : 'webm'}`,
    mime: type,
    size: blob.size,
    date: Date.now(),
    duration,
    width: w,
    height: h,
    fps: state.fps,
    thumb: makeThumb(),
    blob,
  };

  try {
    await idbPut(clip);
  } catch (err) {
    console.warn('indexeddb failed', err);
    toast('Saved to downloads only — browser storage is full');
  }

  setLastThumb(clip.thumb);
  showResult(clip);
}

function makeThumb() {
  try {
    const t = document.createElement('canvas');
    t.width = 216;
    t.height = Math.round(216 * (el.canvas.height / el.canvas.width));
    t.getContext('2d').drawImage(el.canvas, 0, 0, t.width, t.height);
    return t.toDataURL('image/jpeg', 0.6);
  } catch {
    return '';
  }
}

function lockUi(locked) {
  $$('[data-aspect]').forEach((b) => { b.disabled = locked; });
  $$('[data-fps]').forEach((b) => { b.disabled = locked; });
  el.qualityBtn.disabled = locked;
  $$('[data-zoom]').forEach((b) => { b.disabled = locked; });
}

/* ---------------- result + gallery ---------------- */

function showResult(clip) {
  if (lastObjectUrl) URL.revokeObjectURL(lastObjectUrl);
  lastObjectUrl = URL.createObjectURL(clip.blob);
  openSheet(`
    <h2>Reel ready</h2>
    <p class="sub">${clip.width}×${clip.height} · ${clip.fps} FPS · ${fmtSize(clip.size)} · ${clip.mime.includes('mp4') ? 'MP4 / H.264' : 'WebM'}</p>
    <video class="result-video" controls playsinline autoplay muted loop src="${lastObjectUrl}"></video>
    <div class="stat-row">
      <div class="stat">Duration<b>${fmtDur(clip.duration)}</b></div>
      <div class="stat">Size<b>${fmtSize(clip.size)}</b></div>
      <div class="stat">Saved<b>On device</b></div>
    </div>
    <div class="btn-row">
      <button class="btn primary" data-r="share"><svg class="ic"><use href="#i-share"/></svg>Share</button>
      <button class="btn" data-r="download"><svg class="ic"><use href="#i-download"/></svg>Download</button>
    </div>
    <div class="btn-row">
      <button class="btn" data-r="close">Done</button>
    </div>
    <p class="sub" style="margin-top:14px">${clip.mime.includes('mp4')
      ? 'MP4 is upload-ready for Instagram, Facebook and YouTube.'
      : 'This browser recorded WebM. Instagram may reject it — open in Chrome/Edge/Safari for MP4, or convert the file.'}</p>
  `);

  const findClip = async () => (await idbAll()).find((c) => c.id === clip.id) || clip;
  $('#sheetBody [data-r="share"]').addEventListener('click', () => shareClip(clip));
  $('#sheetBody [data-r="download"]').addEventListener('click', () => downloadClip(clip));
  $('#sheetBody [data-r="close"]').addEventListener('click', closeSheet);
  void findClip;
}

function downloadClip(clip) {
  const url = URL.createObjectURL(clip.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = clip.name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

async function shareClip(clip) {
  const file = new File([clip.blob], clip.name, { type: clip.mime });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: 'ProCam Reel' });
      return;
    } catch (err) {
      if (err?.name === 'AbortError') return;
    }
  }
  toast('Share sheet not available — downloading instead');
  downloadClip(clip);
}

function setLastThumb(thumb) {
  if (!thumb) return;
  el.lastThumb.src = thumb;
  el.lastThumb.classList.remove('hidden');
}

async function openGallery() {
  await renderGallery();
  el.gallery.classList.remove('hidden');
}

async function renderGallery() {
  const clips = (await idbAll()).sort((a, b) => b.date - a.date);
  const total = clips.reduce((s, c) => s + c.size, 0);
  el.galleryMeta.textContent = `${clips.length} clip${clips.length === 1 ? '' : 's'} · ${fmtSize(total)} · stored on this device`;
  el.galleryEmpty.classList.toggle('hidden', clips.length > 0);

  el.galleryGrid.innerHTML = clips.map((c) => `
    <button class="gtile" data-clip="${c.id}">
      ${c.thumb ? `<img src="${c.thumb}" alt="" loading="lazy" />` : ''}
      <span class="gscrim"></span>
      <span class="gtag">REEL</span>
      <span class="gdur">${fmtDur(c.duration)}</span>
      <span class="ginfo">
        <span class="gsize">${fmtSize(c.size)}</span><br />
        <span class="gdate">${new Date(c.date).toLocaleDateString()} ${new Date(c.date).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
      </span>
    </button>`).join('');

  $$('#galleryGrid [data-clip]').forEach((tile) => {
    tile.addEventListener('click', async () => {
      const all = await idbAll();
      const clip = all.find((c) => c.id === tile.dataset.clip);
      if (clip) openClipSheet(clip);
    });
  });

  if (clips[0]?.thumb) setLastThumb(clips[0].thumb);
}

function openClipSheet(clip) {
  const url = URL.createObjectURL(clip.blob);
  openSheet(`
    <h2>${clip.name}</h2>
    <p class="sub">${clip.width}×${clip.height} · ${clip.fps} FPS · ${fmtSize(clip.size)} · ${fmtDur(clip.duration)}</p>
    <video class="result-video" controls playsinline autoplay muted loop src="${url}"></video>
    <div class="btn-row">
      <button class="btn primary" data-c="share">Share</button>
      <button class="btn" data-c="download">Download</button>
    </div>
    <div class="btn-row">
      <button class="btn danger" data-c="delete"><svg class="ic"><use href="#i-trash"/></svg>Delete</button>
      <button class="btn" data-c="close">Close</button>
    </div>
  `);
  $('#sheetBody [data-c="share"]').addEventListener('click', () => shareClip(clip));
  $('#sheetBody [data-c="download"]').addEventListener('click', () => downloadClip(clip));
  $('#sheetBody [data-c="close"]').addEventListener('click', () => {
    URL.revokeObjectURL(url);
    closeSheet();
  });
  $('#sheetBody [data-c="delete"]').addEventListener('click', async () => {
    if (!confirm('Delete this clip from the browser gallery?')) return;
    await idbDelete(clip.id);
    URL.revokeObjectURL(url);
    closeSheet();
    await renderGallery();
    toast('Clip deleted');
  });
}

/* ---------------- indexeddb ---------------- */

const DB_NAME = 'procam-web';
const STORE = 'clips';
let dbPromise = null;

function db() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) {
        req.result.createObjectStore(STORE, { keyPath: 'id' });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

async function idbPut(clip) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(clip);
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

async function idbAll() {
  try {
    const d = await db();
    return await new Promise((resolve, reject) => {
      const tx = d.transaction(STORE, 'readonly');
      const req = tx.objectStore(STORE).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = () => reject(req.error);
    });
  } catch {
    return [];
  }
}

async function idbDelete(id) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).delete(id);
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

/* ---------------- sheets ---------------- */

function openSheet(html) {
  el.sheetBody.innerHTML = html;
  el.sheet.classList.remove('hidden');
}

function closeSheet() {
  el.sheet.classList.add('hidden');
  el.sheetBody.innerHTML = '';
}

/* ---------------- teleprompter ---------------- */

function applyPromptStyle() {
  el.promptText.style.setProperty('--p-size', `${state.promptSize}px`);
  el.promptText.style.setProperty('--p-opacity', String(state.promptOpacity));
}

function promptPlay(play) {
  state.promptPlaying = play;
  el.promptPlay.innerHTML = `<svg class="ic"><use href="#i-${play ? 'pause' : 'play'}"/></svg>`;
  if (play && promptOffset === 0) promptLastT = 0;
  if (!play) promptLastT = 0;
}

function promptTick(t) {
  requestAnimationFrame(promptTick);
  if (!state.promptPlaying) return;
  if (!promptLastT) { promptLastT = t; return; }
  const dt = Math.min(0.1, (t - promptLastT) / 1000);
  promptLastT = t;
  promptOffset += state.promptSpeed * dt;

  const max = Math.max(0, el.promptText.scrollHeight - el.promptViewport.clientHeight * 0.75);
  if (promptOffset >= max) {
    promptOffset = max;
    promptPlay(false);
  }
  el.promptText.style.transform = `translate3d(0, ${-promptOffset}px, 0)`;
}

function setPromptText(text) {
  state.script = text;
  el.promptText.textContent = text;
  promptOffset = 0;
  el.promptText.style.transform = 'translate3d(0,0,0)';
}

function openScriptEditor() {
  el.scriptArea.value = state.script;
  el.editor.classList.remove('hidden');
  setTimeout(() => el.scriptArea.focus(), 50);
}

function makePrompterDraggable() {
  const head = el.promptHead;
  let dragging = false;
  let startX = 0;
  let startY = 0;
  let baseL = 0;
  let baseT = 0;

  head.addEventListener('pointerdown', (e) => {
    if (e.target.closest('button')) return;
    dragging = true;
    head.setPointerCapture(e.pointerId);
    const stageBox = el.stage.getBoundingClientRect();
    const box = el.prompter.getBoundingClientRect();
    baseL = box.left - stageBox.left;
    baseT = box.top - stageBox.top;
    startX = e.clientX;
    startY = e.clientY;
  });

  head.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    const stageBox = el.stage.getBoundingClientRect();
    const nextL = Math.min(Math.max(0, baseL + e.clientX - startX), stageBox.width - el.prompter.offsetWidth);
    const nextT = Math.min(Math.max(0, baseT + e.clientY - startY), stageBox.height - el.prompter.offsetHeight);
    el.prompter.style.left = `${nextL}px`;
    el.prompter.style.top = `${nextT}px`;
    el.prompter.style.width = `${el.prompter.offsetWidth}px`;
  });

  const stop = () => { dragging = false; };
  head.addEventListener('pointerup', stop);
  head.addEventListener('pointercancel', stop);
}

/* ---------------- ui wiring ---------------- */

function updateButtons() {
  $$('[data-aspect]').forEach((b) => b.classList.toggle('active', b.dataset.aspect === state.aspect));
  $$('[data-fps]').forEach((b) => b.classList.toggle('active', Number(b.dataset.fps) === state.fps));
  $$('[data-zoom]').forEach((b) => b.classList.toggle('active', Number(b.dataset.zoom) === state.zoom));
  el.gridBtn.classList.toggle('active', state.grid);
  el.grid.classList.toggle('hidden', !state.grid);
  el.prompter.classList.toggle('hidden', !state.promptOn);
  el.qualityBtn.textContent = state.uhd ? '4K' : 'HD';
  $('#promptSpeed').value = state.promptSpeed;
  $('#promptSize').value = state.promptSize;
  $('#promptOpacity').value = Math.round(state.promptOpacity * 100);
}

function setAspect(aspect) {
  if (state.recording || !ASPECTS[aspect]) return;
  state.aspect = aspect;
  applyCanvasSize();
  layoutStage();
  updateButtons();
  saveSettings();
}

function setFps(fps) {
  if (state.recording) return;
  state.fps = fps;
  updateButtons();
  saveSettings();
  stream?.getVideoTracks?.()[0]?.applyConstraints({ frameRate: { ideal: fps } }).catch(() => {});
}

async function toggleQuality() {
  if (state.recording) return;
  state.uhd = !state.uhd;
  const track = stream?.getVideoTracks?.()[0];
  if (track) {
    try {
      await track.applyConstraints({
        width: { ideal: state.uhd ? 3840 : 1920 },
        height: { ideal: state.uhd ? 2160 : 1080 },
      });
    } catch { /* keep old */ }
  }
  const s = await updateQualityLabel();
  if (state.uhd && (s?.height || 0) < 2000) {
    state.uhd = false;
    toast('4K not available on this camera — using 1080p');
  }
  updateButtons();
  saveSettings();
}

function bind() {
  $('#startBtn').addEventListener('click', startCamera);
  el.recBtn.addEventListener('click', () => (state.recording ? stopRecording() : startRecording()));
  el.micBtn.addEventListener('click', openMicSheet);
  el.galleryBtn.addEventListener('click', () => { if (!state.recording) openGallery(); });
  el.qualityBtn.addEventListener('click', toggleQuality);
  el.torchBtn.addEventListener('click', toggleTorch);

  $$('[data-aspect]').forEach((b) => b.addEventListener('click', () => setAspect(b.dataset.aspect)));
  $$('[data-fps]').forEach((b) => b.addEventListener('click', () => setFps(Number(b.dataset.fps))));
  $$('[data-zoom]').forEach((b) => b.addEventListener('click', () => {
    state.zoom = Number(b.dataset.zoom);
    updateButtons();
  }));

  $$('[data-act]').forEach((b) => b.addEventListener('click', (e) => {
    const act = b.dataset.act;
    if (act === 'grid') {
      state.grid = !state.grid;
      updateButtons();
      saveSettings();
    } else if (act === 'flip') {
      if (state.recording) return toast('Stop recording to switch camera');
      state.facing = state.facing === 'user' ? 'environment' : 'user';
      state.torch = false;
      restartVideoTrack();
    } else if (act === 'prompt-toggle') {
      state.promptOn = !state.promptOn;
      updateButtons();
      saveSettings();
    } else if (act === 'prompt-close') {
      state.promptOn = false;
      updateButtons();
      saveSettings();
    } else if (act === 'prompt-edit') {
      openScriptEditor();
    } else if (act === 'prompt-play') {
      promptPlay(!state.promptPlaying);
    } else if (act === 'editor-save') {
      setPromptText(el.scriptArea.value.slice(0, 20_000));
      saveSettings();
      el.editor.classList.add('hidden');
      toast('Script saved');
    } else if (act === 'editor-close') {
      el.editor.classList.add('hidden');
    } else if (act === 'gallery-close') {
      el.gallery.classList.add('hidden');
    }
    if (act && e) e.stopPropagation();
  }));

  el.sheet.addEventListener('click', (e) => {
    if (e.target === el.sheet) closeSheet();
  });

  $('#promptSpeed').addEventListener('input', (e) => {
    state.promptSpeed = Number(e.target.value);
    saveSettings();
  });
  $('#promptSize').addEventListener('input', (e) => {
    state.promptSize = Number(e.target.value);
    applyPromptStyle();
    saveSettings();
  });
  $('#promptOpacity').addEventListener('input', (e) => {
    state.promptOpacity = Number(e.target.value) / 100;
    applyPromptStyle();
    saveSettings();
  });

  window.addEventListener('resize', layoutStage);
  window.addEventListener('orientationchange', () => setTimeout(layoutStage, 150));

  if ('wakeLock' in navigator) {
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden && state.recording) {
        navigator.wakeLock.request('screen').then((w) => { wakeLock = w; }).catch(() => {});
      }
    });
  }
}

function boot() {
  loadSettings();
  applyCanvasSize();
  layoutStage();
  applyPromptStyle();
  setPromptText(state.script);
  updateButtons();
  makePrompterDraggable();
  bind();
  requestAnimationFrame(promptTick);

  if (!navigator.mediaDevices?.getUserMedia) {
    $('#startBtn').textContent = 'HTTPS required';
    $('#startBtn').disabled = true;
    toast('Open this page over HTTPS to use the camera');
  }

  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  }

  idbAll().then((clips) => {
    if (clips.length) {
      const newest = clips.sort((a, b) => b.date - a.date)[0];
      if (newest.thumb) setLastThumb(newest.thumb);
    }
  });
}

window.addEventListener('beforeunload', () => {
  stream?.getTracks().forEach((t) => t.stop());
  stopMic();
  cancelAnimationFrame(rafId);
});

boot();
