import Foundation

/// The dashboard served to phones and tablets.
///
/// One self-contained document: no CDN, no build step, no network beyond the
/// Mac itself — the point is that it works on hotel Wi-Fi with no internet, and
/// that `swift build` remains the only thing anyone has to run.
enum WebApp {
    static func manifest(token: String) -> Data {
        let json: [String: Any] = [
            "name": "NeoStat",
            "short_name": "NeoStat",
            "description": "Live system telemetry from your Mac.",
            "start_url": "/?k=\(token)",
            "scope": "/",
            "display": "standalone",
            "orientation": "any",
            "background_color": "#06070E",
            "theme_color": "#06070E",
            "icons": [
                ["src": "/icon.png", "sizes": "180x180", "type": "image/png"],
                ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png",
                 "purpose": "any maskable"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1">
<title>NeoStat</title>
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="NeoStat">
<meta name="theme-color" content="#06070E">
<style>
:root{
  --void:#06070E; --panel:#0E1220; --cyan:#00E5FF; --magenta:#FF2E88;
  --amber:#FFB321; --danger:#FF3549; --lime:#6DFF7E;
  --bright:#D8F2FF; --dim:#5C7E98; --ghost:#344A60; --rule:#1B2C3E;
  --mono:ui-monospace,"SF Mono",Menlo,"Roboto Mono","Droid Sans Mono",monospace;
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--void);color:var(--bright);font-family:var(--mono)}
body{
  min-height:100svh;
  padding:calc(env(safe-area-inset-top) + 6px) calc(env(safe-area-inset-right) + 10px)
          calc(env(safe-area-inset-bottom) + 6px) calc(env(safe-area-inset-left) + 10px);
  background-image:
    radial-gradient(120% 60% at 50% 0%, rgba(0,229,255,.10), transparent 70%),
    radial-gradient(90% 50% at 100% 100%, rgba(255,46,136,.08), transparent 70%);
  background-attachment:fixed;
  overscroll-behavior:none;
}
/* Scanlines: one fixed layer, so scrolling never repaints a gradient per card. */
body::after{
  content:"";position:fixed;inset:0;pointer-events:none;z-index:50;
  background:repeating-linear-gradient(rgba(0,0,0,.22) 0 1px, transparent 1px 3px);
  opacity:.5;
}
h1,h2,p{margin:0}

/* ---- top bar ---- */
header{
  display:flex;align-items:center;gap:10px;
  padding:6px 2px 10px;position:sticky;top:0;z-index:20;
  background:linear-gradient(var(--void) 72%, transparent);
}
.brand{
  font-size:17px;font-weight:800;letter-spacing:5px;
  text-shadow:0 0 12px rgba(0,229,255,.55);
}
.host{
  font-size:9px;letter-spacing:1.5px;color:var(--dim);
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;min-width:0;
}
.clock{font-size:15px;font-weight:800;letter-spacing:1px;font-variant-numeric:tabular-nums}
.clock .sec{color:var(--cyan);opacity:.75}
.dot{width:8px;height:8px;border-radius:50%;background:var(--lime);box-shadow:0 0 8px var(--lime);flex:none}
.dot.off{background:var(--danger);box-shadow:0 0 8px var(--danger)}

/* ---- grid ---- */
main{display:grid;gap:10px;grid-template-columns:1fr;padding-bottom:12px}
@media(min-width:620px){main{grid-template-columns:1fr 1fr}}
@media(min-width:1040px){main{grid-template-columns:repeat(3,1fr)}}
.card{
  position:relative;background:rgba(14,18,32,.55);border:1px solid var(--rule);
  border-radius:3px;padding:11px 12px 13px;
}
.card::before,.card::after{
  content:"";position:absolute;width:11px;height:11px;border:1px solid rgba(0,229,255,.5);
}
.card::before{top:-1px;left:-1px;border-right:0;border-bottom:0}
.card::after{bottom:-1px;right:-1px;border-left:0;border-top:0}
.span2{grid-column:span 1}
@media(min-width:620px){.span2{grid-column:span 2}}
@media(min-width:1040px){.span2{grid-column:span 1}}

.cap{display:flex;align-items:center;gap:8px;margin-bottom:9px}
.cap b{font-size:9.5px;font-weight:700;letter-spacing:2.2px;color:var(--cyan)}
.cap .line{flex:1;height:1px;background:var(--rule)}
.cap s{font-size:8.5px;letter-spacing:1.4px;color:var(--dim);text-decoration:none}

.big{display:flex;align-items:baseline;gap:4px}
.big .v{font-size:44px;font-weight:900;line-height:.95;font-variant-numeric:tabular-nums;letter-spacing:-1px}
.big .u{font-size:15px;font-weight:700;opacity:.5}
.big .side{margin-left:auto;text-align:right;display:grid;gap:3px}
.kv{font-size:9.5px;letter-spacing:.6px;color:var(--ghost)}
.kv b{font-size:11px;font-weight:700;letter-spacing:0;margin-left:5px}

canvas{display:block;width:100%;height:56px;margin:9px 0 4px}
canvas.tall{height:74px}

.dual{display:flex;gap:12px}
.dual>div{flex:1;min-width:0}
.dual em{display:block;font-style:normal;font-size:8px;letter-spacing:1.5px;color:var(--ghost)}
.dual b{display:block;font-size:29px;font-weight:900;line-height:1.15;margin-top:3px;
        font-variant-numeric:tabular-nums}

/* Propped on a desk, a tablet should fill its screen rather than leave a third
   of it black: cards stretch and their traces take the slack. */
@media(min-width:1040px) and (min-height:600px){
  main{min-height:calc(100svh - 92px);grid-auto-rows:minmax(0,1fr)}
  .card{display:flex;flex-direction:column}
  .card canvas{flex:1 1 auto;min-height:56px}
  .card table{margin-top:2px}
}

.cores{display:flex;gap:3px;align-items:flex-end;height:40px;margin-top:8px}
.cores i{flex:1;background:var(--cyan);border-radius:1px 1px 0 0;min-height:2px;transition:height .18s linear}

.meter{margin:7px 0 2px}
.meter .top{display:flex;justify-content:space-between;font-size:9.5px;letter-spacing:1.2px;color:var(--dim)}
.meter .top b{color:var(--bright);font-size:10.5px}
.meter .track{height:7px;background:rgba(255,255,255,.06);border-radius:2px;overflow:hidden;margin-top:4px;display:flex}
.meter .track i{height:100%;display:block}

.tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;margin-top:10px}
.tile{background:rgba(255,255,255,.035);border-left:2px solid var(--rule);padding:5px 6px}
.tile em{display:block;font-size:7.5px;font-style:normal;letter-spacing:1.3px;color:var(--ghost)}
.tile b{display:block;font-size:12px;font-weight:700;margin-top:2px;font-variant-numeric:tabular-nums}

table{width:100%;border-collapse:collapse;font-size:11px}
td{padding:3px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
td.n{max-width:0;width:100%;color:var(--bright)}
td.r{text-align:right;font-variant-numeric:tabular-nums;color:var(--cyan);padding-left:8px}
td.p{color:var(--ghost);font-size:9.5px;padding-right:7px}
.tabs{display:flex;gap:6px;margin-left:auto}
.tabs button{
  background:none;border:1px solid var(--rule);color:var(--ghost);font:inherit;
  font-size:8px;letter-spacing:1.3px;padding:3px 7px;border-radius:2px;cursor:pointer
}
.tabs button.on{color:var(--cyan);border-color:rgba(0,229,255,.5)}

.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:9px}
.chip{
  font-size:8.5px;letter-spacing:1.3px;padding:4px 7px;border-radius:2px;
  border:1px solid var(--rule);color:var(--ghost)
}
.chip.on{color:var(--void);background:var(--lime);border-color:var(--lime);font-weight:700}
.chip.warn{color:var(--void);background:var(--amber);border-color:var(--amber);font-weight:700}
.chip.bad{color:#fff;background:var(--danger);border-color:var(--danger);font-weight:700}

footer{
  display:flex;align-items:center;gap:9px;padding:9px 2px 4px;
  font-size:9px;letter-spacing:1.3px;color:var(--ghost);
}
footer .line{flex:1;height:1px;background:var(--rule)}
footer button{
  background:none;border:1px solid var(--rule);color:var(--dim);font:inherit;
  font-size:8.5px;letter-spacing:1.3px;padding:5px 9px;border-radius:2px;cursor:pointer
}
footer button.on{color:var(--lime);border-color:rgba(109,255,126,.55)}

#offline{
  position:fixed;left:50%;transform:translateX(-50%);bottom:calc(env(safe-area-inset-bottom) + 14px);
  z-index:60;background:var(--danger);color:#fff;font-size:10px;letter-spacing:1.6px;font-weight:700;
  padding:8px 14px;border-radius:3px;display:none;box-shadow:0 6px 24px rgba(0,0,0,.5)
}
#offline.show{display:block}
</style>
</head>
<body>

<header>
  <span class="brand">NEOSTAT</span>
  <span class="host" id="host">CONNECTING…</span>
  <span class="clock" id="clock">--:--<span class="sec">:--</span></span>
  <span class="dot off" id="dot"></span>
</header>

<main>
  <section class="card">
    <div class="cap"><b>PROCESSOR</b><span class="line"></span><s id="cpu-state">—</s></div>
    <div class="big">
      <span class="v" id="cpu-v">0</span><span class="u">%</span>
      <span class="side">
        <span class="kv">USR<b id="cpu-usr" style="color:var(--cyan)">0%</b></span>
        <span class="kv">SYS<b id="cpu-sys" style="color:var(--magenta)">0%</b></span>
      </span>
    </div>
    <canvas id="cpu-spark" class="tall"></canvas>
    <div class="cores" id="cores"></div>
    <div class="tiles">
      <div class="tile"><em>LOAD 1M</em><b id="l1">0</b></div>
      <div class="tile"><em>5M</em><b id="l5">0</b></div>
      <div class="tile"><em>15M</em><b id="l15">0</b></div>
      <div class="tile"><em>PEAK</em><b id="cpu-peak" style="color:var(--amber)">0%</b></div>
    </div>
  </section>

  <section class="card">
    <div class="cap"><b>MEMORY</b><span class="line"></span><s id="mem-state">—</s></div>
    <div class="big">
      <span class="v" id="mem-v">0</span><span class="u">%</span>
      <span class="side">
        <span class="kv">USED<b id="mem-used">0G</b></span>
        <span class="kv">OF<b id="mem-total">0G</b></span>
      </span>
    </div>
    <canvas id="mem-spark"></canvas>
    <div class="meter">
      <div class="top"><span>BREAKDOWN</span><b id="mem-break">—</b></div>
      <div class="track" id="mem-track">
        <i style="background:var(--cyan)"></i><i style="background:var(--magenta)"></i>
        <i style="background:var(--amber)"></i><i style="background:rgba(109,255,126,.55)"></i>
      </div>
    </div>
    <div class="tiles">
      <div class="tile"><em>APP</em><b id="m-app">0</b></div>
      <div class="tile"><em>WIRED</em><b id="m-wired">0</b></div>
      <div class="tile"><em>COMP</em><b id="m-comp">0</b></div>
      <div class="tile"><em>SWAP</em><b id="m-swap" style="color:var(--amber)">0</b></div>
    </div>
  </section>

  <section class="card">
    <div class="cap"><b>NETWORK</b><span class="line"></span><s id="net-state">IDLE</s></div>
    <div class="dual">
      <div><em>↓ DOWN</em><b id="net-rx" style="color:var(--cyan)">0</b></div>
      <div><em>↑ UP</em><b id="net-tx" style="color:var(--magenta)">0</b></div>
    </div>
    <canvas id="net-spark" class="tall"></canvas>
  </section>

  <section class="card">
    <div class="cap"><b>DISK &amp; GPU</b><span class="line"></span><s id="gpu-state">—</s></div>
    <div class="meter">
      <div class="top"><span>GPU</span><b id="gpu-v">0%</b></div>
      <div class="track"><i id="gpu-bar" style="width:0;background:var(--cyan)"></i></div>
    </div>
    <canvas id="disk-spark"></canvas>
    <div class="meter">
      <div class="top"><span>VOLUME /</span><b id="vol-v">—</b></div>
      <div class="track"><i id="vol-bar" style="width:0;background:var(--cyan)"></i></div>
    </div>
    <div class="tiles">
      <div class="tile"><em>READ</em><b id="d-r">0</b></div>
      <div class="tile"><em>WRITE</em><b id="d-w">0</b></div>
      <div class="tile"><em>FREE</em><b id="d-free" style="color:var(--lime)">0</b></div>
      <div class="tile"><em>TASKS</em><b id="tasks">0</b></div>
    </div>
  </section>

  <section class="card span2">
    <div class="cap"><b>PROCESSES</b><span class="line"></span>
      <span class="tabs">
        <button id="tab-cpu" class="on">CPU</button><button id="tab-mem">MEM</button>
      </span>
    </div>
    <table><tbody id="proc"></tbody></table>
  </section>

  <section class="card">
    <div class="cap"><b>POWER &amp; SENSORS</b><span class="line"></span><s id="pwr-state">—</s></div>
    <div class="big">
      <span class="v" id="bat-v" style="font-size:34px">—</span><span class="u">%</span>
      <span class="side">
        <span class="kv">TIME<b id="bat-rem">—</b></span>
        <span class="kv">CYCLES<b id="bat-cyc">—</b></span>
      </span>
    </div>
    <div class="meter">
      <div class="track"><i id="bat-bar" style="width:0;background:var(--lime)"></i></div>
    </div>
    <div class="chips" id="chips"></div>
    <div class="tiles">
      <div class="tile"><em>VOLTS</em><b id="s-v">—</b></div>
      <div class="tile"><em>AMPS</em><b id="s-a">—</b></div>
      <div class="tile"><em>THERMAL</em><b id="s-t">—</b></div>
      <div class="tile"><em>PRESSURE</em><b id="s-p">—</b></div>
    </div>
  </section>
</main>

<footer>
  <span>UPTIME</span><b id="up" style="color:var(--dim)">—</b>
  <span class="line"></span>
  <button id="awake">KEEP AWAKE</button>
  <button id="full">FULL</button>
</footer>

<div id="offline">LINK LOST — RETRYING</div>

<script>
(() => {
  const K = new URLSearchParams(location.search).get('k') || '';
  const $ = id => document.getElementById(id);
  const dpr = () => Math.min(window.devicePixelRatio || 1, 2);

  const CY='#00E5FF', MG='#FF2E88', AM='#FFB321', DG='#FF3549', LM='#6DFF7E';
  const heat = f => f < .35 ? CY : f < .55 ? LM : f < .75 ? AM : f < .90 ? MG : DG;
  const pct = f => Math.round(Math.min(Math.max(f,0),1)*100);
  const gb  = b => (b/1073741824).toFixed(b < 10737418240 ? 1 : 0) + 'G';
  const rate = b => b < 1024 ? Math.round(b)+'B'
    : b < 1048576 ? (b/1024).toFixed(0)+'K'
    : b < 1073741824 ? (b/1048576).toFixed(1)+'M' : (b/1073741824).toFixed(2)+'G';
  const dur = s => {
    s = Math.max(0, s|0);
    const d = s/86400|0, h = (s%86400)/3600|0, m = (s%3600)/60|0;
    return d ? d+'D '+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')
             : String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(s%60).padStart(2,'0');
  };

  // ---- canvas traces -------------------------------------------------------
  function draw(id, sets, opts = {}) {
    const c = $(id), r = dpr();
    const w = c.clientWidth, h = c.clientHeight;
    if (!w || !h) return;
    if (c.width !== w*r || c.height !== h*r) { c.width = w*r; c.height = h*r; }
    const x = c.getContext('2d');
    x.setTransform(r,0,0,r,0,0);
    x.clearRect(0,0,w,h);

    // baseline grid — three lines, enough to read amplitude, cheap to paint
    x.strokeStyle = 'rgba(27,44,62,.85)'; x.lineWidth = 1;
    for (let i=1;i<4;i++){ const y=h*i/4|0; x.beginPath(); x.moveTo(0,y+.5); x.lineTo(w,y+.5); x.stroke(); }

    let top = opts.max || 0;
    if (!opts.max) for (const s of sets) for (const v of s.v) if (v > top) top = v;
    top = Math.max(top, opts.floor || 1);

    for (const s of sets) {
      const vals = s.v; if (!vals || vals.length < 2) continue;
      const step = w / (vals.length - 1);
      const y = v => h - (Math.min(v, top) / top) * (h - 3) - 1.5;

      x.beginPath(); x.moveTo(0, y(vals[0]));
      for (let i=1;i<vals.length;i++) x.lineTo(i*step, y(vals[i]));

      if (s.fill !== false) {
        const g = x.createLinearGradient(0,0,0,h);
        g.addColorStop(0, s.c + '55'); g.addColorStop(1, s.c + '00');
        x.save(); x.lineTo(w,h); x.lineTo(0,h); x.closePath();
        x.fillStyle = g; x.fill(); x.restore();
        x.beginPath(); x.moveTo(0, y(vals[0]));
        for (let i=1;i<vals.length;i++) x.lineTo(i*step, y(vals[i]));
      }
      x.strokeStyle = s.c; x.lineWidth = 1.6; x.lineJoin = 'round'; x.stroke();

      const last = vals[vals.length-1];
      x.fillStyle = s.c; x.beginPath();
      x.arc(w-1.5, y(last), 2.2, 0, 6.284); x.fill();
    }
  }

  // Fractions arrive as permille integers and hundredths (see StatsJSON);
  // undo that once here so every render path below is in plain 0..1 units.
  function unpack(d) {
    const M = 1000, C = 100, c = d.cpu;
    c.total/=M; c.user/=M; c.sys/=M; c.peak/=M;
    c.per = c.per.map(v => v/M);
    c.series = c.series.map(v => v/M);
    c.load = c.load.map(v => v/C);
    d.gpu.util/=M; d.gpu.series = d.gpu.series.map(v => v/M);
    d.mem.fraction/=M; d.mem.series = d.mem.series.map(v => v/M);
    d.disk.volFraction/=M;
    d.proc.cpu.forEach(p => p.cpu/=C);
    d.proc.mem.forEach(p => p.cpu/=C);
    d.sensors.volts/=C; d.sensors.amps/=C;
    return d;
  }

  // ---- render --------------------------------------------------------------
  let mode = 'cpu';
  let cores = [];

  function render(d) {
    $('host').textContent = (d.host || '').toUpperCase() + ' · ' + d.chip + ' · ' + d.cpu.cores + 'C';

    // CPU
    const c = d.cpu, col = heat(c.total);
    const v = $('cpu-v');
    v.textContent = pct(c.total); v.style.color = col;
    v.style.textShadow = '0 0 18px ' + col + '88';
    $('cpu-usr').textContent = pct(c.user) + '%';
    $('cpu-sys').textContent = pct(c.sys) + '%';
    $('cpu-state').textContent = d.stressed ? '⚠ LOAD' : 'NOMINAL';
    $('cpu-state').style.color = d.stressed ? DG : '';
    $('l1').textContent = c.load[0].toFixed(2);
    $('l5').textContent = c.load[1].toFixed(2);
    $('l15').textContent = c.load[2].toFixed(2);
    $('cpu-peak').textContent = pct(c.peak) + '%';
    draw('cpu-spark', [{v:c.series, c:col}], {max:1});

    if (cores.length !== c.per.length) {
      const box = $('cores'); box.innerHTML = '';
      cores = c.per.map(() => box.appendChild(document.createElement('i')));
    }
    c.per.forEach((f, i) => {
      cores[i].style.height = Math.max(f*100, 3) + '%';
      cores[i].style.background = heat(f);
      cores[i].style.opacity = i < c.eff ? .55 : 1;
    });

    // Memory
    const m = d.mem, mcol = heat(m.fraction);
    $('mem-v').textContent = pct(m.fraction);
    $('mem-v').style.color = mcol;
    $('mem-used').textContent = gb(m.used);
    $('mem-total').textContent = gb(m.total);
    $('mem-state').textContent = m.pressureLabel;
    $('mem-state').style.color = m.pressure > 1 ? AM : '';
    draw('mem-spark', [{v:m.series, c:mcol}], {max:1});
    const seg = $('mem-track').children;
    const tot = m.total || 1;
    [m.app, m.wired, m.compressed, m.cached].forEach((val,i) => {
      seg[i].style.width = (val/tot*100).toFixed(1) + '%';
    });
    $('mem-break').textContent = 'APP · WIRED · COMP · CACHE';
    $('m-app').textContent = gb(m.app);
    $('m-wired').textContent = gb(m.wired);
    $('m-comp').textContent = gb(m.compressed);
    $('m-swap').textContent = gb(m.swapUsed);

    // Network
    $('net-rx').textContent = rate(d.net.rx);
    $('net-tx').textContent = rate(d.net.tx);
    $('net-state').textContent = (d.net.rx + d.net.tx) > 65536 ? 'ACTIVE' : 'IDLE';
    draw('net-spark', [{v:d.net.rxSeries, c:CY},{v:d.net.txSeries, c:MG, fill:false}], {floor:65536});

    // Disk + GPU
    const g = d.gpu;
    $('gpu-v').textContent = g.available ? pct(g.util) + '%' : 'N/A';
    $('gpu-bar').style.width = (g.available ? pct(g.util) : 0) + '%';
    $('gpu-bar').style.background = heat(g.util);
    $('gpu-state').textContent = g.available ? 'IOACCEL' : 'NO GPU';
    draw('disk-spark', [{v:d.disk.readSeries, c:LM},{v:d.disk.writeSeries, c:AM, fill:false}], {floor:262144});
    $('vol-v').textContent = gb(d.disk.volTotal - d.disk.volFree) + ' / ' + gb(d.disk.volTotal);
    $('vol-bar').style.width = pct(d.disk.volFraction) + '%';
    $('d-r').textContent = rate(d.disk.read);
    $('d-w').textContent = rate(d.disk.write);
    $('d-free').textContent = gb(d.disk.volFree);
    $('tasks').textContent = d.proc.count;

    // Processes
    const list = mode === 'cpu' ? d.proc.cpu : d.proc.mem;
    $('proc').innerHTML = list.map(p =>
      '<tr><td class="p">' + p.pid + '</td><td class="n">' + esc(p.name) + '</td><td class="r">' +
      (mode === 'cpu' ? p.cpu.toFixed(1) + '%' : gb(p.rss)) + '</td></tr>').join('');

    // Power + sensors
    const s = d.sensors;
    $('bat-v').textContent = s.hasBattery ? s.percent : '—';
    $('bat-bar').style.width = (s.hasBattery ? s.percent : 0) + '%';
    $('bat-bar').style.background = s.percent < 20 && !s.charging ? DG : s.charging ? CY : LM;
    $('bat-rem').textContent = s.minutes > 0 ? ((s.minutes/60|0) + 'H' + String(s.minutes%60).padStart(2,'0')) : '—';
    $('bat-cyc').textContent = s.cycles || '—';
    $('pwr-state').textContent = s.power;
    $('s-v').textContent = s.volts ? s.volts.toFixed(2) : '—';
    $('s-a').textContent = s.amps ? s.amps.toFixed(2) : '—';
    $('s-t').textContent = s.thermalLabel;
    $('s-p').textContent = m.pressureLabel;
    $('chips').innerHTML =
      chip('CAM', s.camera, 'bad') + chip('MIC', s.mic, 'warn') +
      chip('LOW PWR', s.lowPower, 'warn') + chip(s.charging ? 'CHARGING' : 'ON ' + (s.onAC ? 'AC' : 'BATTERY'), s.charging || s.onAC, 'on');

    $('up').textContent = dur(d.up);
    tickClock(d.clock);
  }

  const chip = (label, on, kind) => '<span class="chip' + (on ? ' ' + kind : '') + '">' + label + '</span>';
  const esc = s => s.replace(/[<>&]/g, ch => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[ch]));

  // Clock runs off the Mac's timestamp so both screens agree, then free-runs
  // between packets — one interval, not one per frame.
  let skew = 0;
  const tickClock = mac => { if (mac) skew = mac*1000 - Date.now(); };
  setInterval(() => {
    const t = new Date(Date.now() + skew);
    const p = n => String(n).padStart(2,'0');
    $('clock').innerHTML = p(t.getHours()) + ':' + p(t.getMinutes()) +
      '<span class="sec">:' + p(t.getSeconds()) + '</span>';
  }, 1000);

  $('tab-cpu').onclick = () => { mode='cpu'; $('tab-cpu').classList.add('on'); $('tab-mem').classList.remove('on'); if (last) render(last); };
  $('tab-mem').onclick = () => { mode='mem'; $('tab-mem').classList.add('on'); $('tab-cpu').classList.remove('on'); if (last) render(last); };

  // ---- link ----------------------------------------------------------------
  let last = null, es = null, alive = 0;

  function live(on) {
    $('dot').classList.toggle('off', !on);
    $('offline').classList.toggle('show', !on);
  }

  function connect() {
    if (es) es.close();
    es = new EventSource('/api/stream?k=' + encodeURIComponent(K));
    es.onmessage = e => {
      alive = Date.now();
      live(true);
      try { last = unpack(JSON.parse(e.data)); render(last); } catch (err) {}
    };
    es.onerror = () => live(false);
  }
  connect();

  // A phone that slept drops the stream without telling anyone; re-open on wake
  // and whenever packets stop arriving.
  setInterval(() => { if (Date.now() - alive > 6000) { live(false); connect(); } }, 4000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) connect(); });
  window.addEventListener('resize', () => { if (last) render(last); });

  // ---- screen controls -----------------------------------------------------
  let lock = null;
  $('awake').onclick = async () => {
    try {
      if (lock) { await lock.release(); lock = null; $('awake').classList.remove('on'); return; }
      lock = await navigator.wakeLock.request('screen');
      lock.addEventListener('release', () => { lock = null; $('awake').classList.remove('on'); });
      $('awake').classList.add('on');
    } catch (e) { $('awake').textContent = 'NO WAKE LOCK'; }
  };
  document.addEventListener('visibilitychange', async () => {
    if (!document.hidden && $('awake').classList.contains('on') && !lock) {
      try { lock = await navigator.wakeLock.request('screen'); } catch (e) {}
    }
  });
  $('full').onclick = () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen?.();
  };
})();
</script>
</body>
</html>
"""#
}
