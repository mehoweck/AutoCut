/* app.js — dialog controller for AutoCut & BOM */

var currentTab = 'instances';

// ── Bootstrap ────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', function () {
  // Notify Ruby that the DOM is ready so it can push the initial data payload.
  sketchup.ready();

  ['src-len', 'cut-loss'].forEach(function (id) {
    var el = document.getElementById(id);
    if (el) el.addEventListener('keydown', function (e) { if (e.key === 'Enter') doRecalc(); });
  });
});

// Called by Ruby once after DOMContentLoaded with the full initial dataset.
function initData(data) {
  var inv = data.invalidCount > 0
    ? ' \u00a0\u26a0 ' + data.invalidCount + ' invalid'
    : '';
  document.getElementById('scope-label').innerHTML =
    '\uD83D\uDD0D ' + data.scope + ' &nbsp;|&nbsp; ' + data.totalCount + ' components' + inv;

  document.getElementById('src-len').value     = data.srcLengths;
  document.getElementById('cut-loss').value    = data.cutLoss;
  document.getElementById('algo-select').value = data.solverName || 'greedy';

  updateInstances(data.instanceRows);
  updateAggregated(data.aggRows);
  updateOrderSummary(data.orderRows);
  updateMbVolume(data.mbVolRows);
  changeUnit();
}

// ── Tab switching ─────────────────────────────────────────────────────────────

function switchTab(tab) {
  currentTab  = tab;
  var isInst  = tab === 'instances';
  document.getElementById('view-instances').className  = isInst ? 'view active' : 'view';
  document.getElementById('view-aggregated').className = isInst ? 'view' : 'view active';
  document.getElementById('btn-inst').className        = isInst ? 'tab-btn active' : 'tab-btn';
  document.getElementById('btn-agg').className         = isInst ? 'tab-btn' : 'tab-btn active';
  document.getElementById('inst-controls').style.display = isInst ? 'flex' : 'none';
  document.getElementById('agg-controls').style.display  = isInst ? 'none' : 'flex';
}

// ── Unit conversion ───────────────────────────────────────────────────────────

function fmtLen(mm, unit) {
  var v = parseFloat(mm);
  if (!mm || isNaN(v) || v === 0) return '\u2014';
  if (unit === 'mm') return Math.round(v) + '';
  if (unit === 'cm') {
    var c = v / 10;
    return c === Math.round(c) ? Math.round(c) + '' : c.toFixed(1).replace(/\.0$/, '');
  }
  if (unit === 'm') return (v / 1000).toFixed(2).replace(/\.?0+$/, '');
  return v + '';
}

function changeUnit() {
  var unit   = document.getElementById('unit-select').value;
  var labels = { mm: 'Length [mm]', cm: 'Length [cm]', m: 'Length [m]' };
  document.getElementById('inst-len-hdr').textContent = labels[unit] || 'Length';
  document.querySelectorAll('#tbl-inst .len-cell').forEach(function (td) {
    td.textContent = fmtLen(td.getAttribute('data-mm'), unit);
  });
}

// ── CSV export ────────────────────────────────────────────────────────────────

function doSave() {
  if (currentTab === 'instances') sketchup.save_instances_csv();
  else sketchup.save_aggregated_csv();
}

// ── Recalculate ───────────────────────────────────────────────────────────────

function doRecalc() {
  var s  = document.getElementById('src-len').value.trim();
  var l  = parseFloat(document.getElementById('cut-loss').value);
  var bf = document.getElementById('algo-select').value;
  if (!s)               { alert('Enter stock lengths, e.g. 100,150,200'); return; }
  if (isNaN(l) || l < 0) { alert('Kerf loss must be \u2265 0.');          return; }
  sketchup.recalculate(s + '|' + l + '|' + bf);
}

// ── Table renderers ───────────────────────────────────────────────────────────

function updateInstances(rows) {
  var unit  = document.getElementById('unit-select').value;
  var tbody = document.getElementById('tbl-inst-body');
  tbody.innerHTML = '';
  rows.forEach(function (r) {
    var cls = r.invalid ? ' class="row-invalid"' : '';
    var ok  = r.invalid ? '&#9888;' : '&#10003;';
    var tip = r.invalid ? ' title="Dimension mismatch: bbox vs name"' : '';
    tbody.innerHTML +=
      '<tr' + cls + '>' +
      '<td class="name-col"' + tip + '>' + r.name + '</td>' +
      '<td class="len-cell" data-mm="' + r.lengthMm + '">' + fmtLen(r.lengthMm, unit) + '</td>' +
      '<td><b>' + r.count + '</b></td>' +
      '<td style="text-align:center">' + ok + '</td>' +
      '</tr>';
  });
}

function updateAggregated(rows) {
  var tbody = document.getElementById('tbl-agg-body');
  tbody.innerHTML = '';
  rows.forEach(function (g) {
    var cls = (g.invalid || g.unfit) ? ' class="row-invalid"' : '';
    var ok  = g.invalid ? '&#9888;' : '&#10003;';
    var srcLens, nBins, plan;

    if (g.unfit) {
      var tip = 'Element ' + g.length + ' cm exceeds all available stock lengths';
      srcLens = '<span style="color:#c0392b;font-weight:bold" title="' + tip + '">Too long!</span>';
      nBins   = '<span style="color:#c0392b">&mdash;</span>';
      plan    = '<span style="color:#c0392b" title="' + tip + '">No matching stock</span>';
    } else {
      srcLens = [...new Set(g.bins.map(function (b) { return b.src; }))]
        .sort(function(a,b){return a-b;})
        .map(function (s) { return Math.round(s); }).join(', ') || '&mdash;';
      nBins = g.bins.length || '&mdash;';
      plan  = g.bins.map(function (b) {
        var cuts = b.cuts.map(function (c) { return Math.round(c); }).join('+');
        var rest = b.rest > 0.05 ? ' r' + Math.round(b.rest) : '';
        return Math.round(b.src) + '(' + cuts + rest + ')';
      }).join(' | ') || '&mdash;';
    }

    tbody.innerHTML +=
      '<tr' + cls + '>' +
      '<td class="name-col" title="' + g.name + '">' + g.name + '</td>' +
      '<td>' + g.cross  + '</td>' +
      '<td>' + g.length + '</td>' +
      '<td><b>' + g.count + '</b></td>' +
      '<td>' + srcLens + '</td>' +
      '<td><b>' + nBins + '</b></td>' +
      '<td class="plan-col" title="' + plan + '">' + plan + '</td>' +
      '<td style="text-align:center">' + ok + '</td>' +
      '</tr>';
  });
  var stats = document.getElementById('agg-stats');
  if (stats) stats.textContent = rows.length + ' definitions';
}

function updateOrderSummary(rows) {
  var tbody     = document.getElementById('order-body');
  tbody.innerHTML = '';
  var lastCross = null;
  rows.forEach(function (r) {
    if (lastCross !== null && r.cross !== lastCross) {
      tbody.innerHTML +=
        '<tr class="order-sep"><td colspan="4" style="padding:0;border:none;background:#f0f0f0;height:6px"></td></tr>';
    }
    tbody.innerHTML +=
      '<tr>' +
      '<td class="name-col">' + r.cross + '</td>' +
      '<td>' + r.sl    + '</td>' +
      '<td><b>' + r.count + '</b></td>' +
      '<td>' + r.lm    + '</td>' +
      '</tr>';
    lastCross = r.cross;
  });
}

function updateMbVolume(rows) {
  var tbodyLm  = document.getElementById('mb-body');
  var tbodyVol = document.getElementById('vol-body');
  tbodyLm.innerHTML = tbodyVol.innerHTML = '';
  rows.forEach(function (r) {
    tbodyLm.innerHTML  += '<tr><td class="name-col">' + r.cross + '</td><td>' + r.lm  + '</td></tr>';
    tbodyVol.innerHTML += '<tr><td class="name-col">' + r.cross + '</td><td>' + r.m3  + '</td></tr>';
  });
}

// ── Column sorting ────────────────────────────────────────────────────────────

function sortTable(tableId, colIdx, isText) {
  var table = document.getElementById(tableId);
  var tbody = table.tBodies[0];
  var rows  = Array.from(tbody.rows);
  var ths   = table.tHead.rows[0].cells;
  var th    = ths[colIdx];
  var asc   = !th.classList.contains('sorted-asc');

  Array.from(ths).forEach(function (h) { h.classList.remove('sorted-asc', 'sorted-desc'); });
  th.classList.add(asc ? 'sorted-asc' : 'sorted-desc');

  rows.sort(function (a, b) {
    var av = a.cells[colIdx] ? a.cells[colIdx].textContent.trim() : '';
    var bv = b.cells[colIdx] ? b.cells[colIdx].textContent.trim() : '';
    if (!isText) {
      var an = parseFloat(av), bn = parseFloat(bv);
      if (!isNaN(an) && !isNaN(bn)) return asc ? an - bn : bn - an;
    }
    return asc ? av.localeCompare(bv) : bv.localeCompare(av);
  });
  rows.forEach(function (r) { tbody.appendChild(r); });
}
