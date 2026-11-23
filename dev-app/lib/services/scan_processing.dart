import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Bildbearbeitung für Scans – läuft in einem Isolate (compute()).
///
/// Pipeline: Perspektive entzerren → drehen → Filter → Helligkeit/Kontrast.

enum ScanFilter { original, enhanced, gray, bw }

extension ScanFilterLabel on ScanFilter {
  String get label => switch (this) {
        ScanFilter.original => 'Original',
        ScanFilter.enhanced => 'Farbe+',
        ScanFilter.gray => 'Graustufen',
        ScanFilter.bw => 'Schwarzweiß',
      };
}

class RawRgba {
  RawRgba(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

class ScanJob {
  ScanJob({
    required this.src,
    required this.corners,
    required this.filter,
    required this.brightness,
    required this.contrast,
    required this.quarterTurns,
    required this.maxSide,
    this.encode = false,
  });

  final RawRgba src;

  /// 8 Werte, normiert 0..1: oben-links, oben-rechts, unten-rechts, unten-links (x,y).
  final List<double> corners;
  final ScanFilter filter;

  /// -1..1
  final double brightness;

  /// -1..1
  final double contrast;
  final int quarterTurns;
  final int maxSide;

  /// true: Ergebnis als Datei-Bytes (JPEG bzw. PNG bei Schwarzweiß).
  final bool encode;
}

class ScanResult {
  ScanResult({
    required this.width,
    required this.height,
    this.rgba,
    this.fileBytes,
    this.isPng = false,
  });
  final int width;
  final int height;
  final Uint8List? rgba;
  final Uint8List? fileBytes;
  final bool isPng;
}

ScanResult processScan(ScanJob job) {
  var out = _warp(job.src, job.corners, job.maxSide);
  out = _rotate(out, job.quarterTurns);
  final gray = job.filter == ScanFilter.gray || job.filter == ScanFilter.bw;
  _applyFilter(out, job.filter, job.brightness, job.contrast);

  if (!job.encode) {
    return ScanResult(width: out.width, height: out.height, rgba: out.bytes);
  }
  if (job.filter == ScanFilter.bw) {
    // Schwarzweiß als Graustufen-PNG: gestochen scharf und klein
    final g = Uint8List(out.width * out.height);
    for (var i = 0, j = 0; i < g.length; i++, j += 4) {
      g[i] = out.bytes[j];
    }
    final im = img.Image.fromBytes(
      width: out.width,
      height: out.height,
      bytes: g.buffer,
      numChannels: 1,
    );
    return ScanResult(
      width: out.width,
      height: out.height,
      fileBytes: img.encodePng(im, level: 6),
      isPng: true,
    );
  }
  final im = img.Image.fromBytes(
    width: out.width,
    height: out.height,
    bytes: out.bytes.buffer,
    numChannels: 4,
  );
  return ScanResult(
    width: out.width,
    height: out.height,
    fileBytes: img.encodeJpg(im, quality: gray ? 86 : 88),
  );
}

// ---------------------------------------------------------------------------
// Perspektive

RawRgba _warp(RawRgba src, List<double> c, int maxSide) {
  final sw = src.width, sh = src.height;
  final pts = <math.Point<double>>[
    for (var i = 0; i < 4; i++) math.Point(c[i * 2] * (sw - 1), c[i * 2 + 1] * (sh - 1)),
  ];
  double dist(math.Point<double> a, math.Point<double> b) => a.distanceTo(b);
  var w = math.max(dist(pts[0], pts[1]), dist(pts[3], pts[2]));
  var h = math.max(dist(pts[0], pts[3]), dist(pts[1], pts[2]));
  if (w < 8 || h < 8) {
    w = sw.toDouble();
    h = sh.toDouble();
  }
  final s = math.min(1.0, maxSide / math.max(w, h));
  final ow = math.max(1, (w * s).round());
  final oh = math.max(1, (h * s).round());

  final hm = _homography(
    [0, 0, ow - 1.0, 0, ow - 1.0, oh - 1.0, 0, oh - 1.0],
    [for (final p in pts) ...[p.x, p.y]],
  );
  final out = Uint8List(ow * oh * 4);
  final sb = src.bytes;
  final maxX = sw - 1, maxY = sh - 1;
  var o = 0;
  for (var y = 0; y < oh; y++) {
    final yy = y.toDouble();
    for (var x = 0; x < ow; x++) {
      final xx = x.toDouble();
      final d = hm[6] * xx + hm[7] * yy + 1.0;
      var u = (hm[0] * xx + hm[1] * yy + hm[2]) / d;
      var v = (hm[3] * xx + hm[4] * yy + hm[5]) / d;
      if (u < 0) u = 0;
      if (v < 0) v = 0;
      if (u > maxX) u = maxX.toDouble();
      if (v > maxY) v = maxY.toDouble();
      final x0 = u.floor(), y0 = v.floor();
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final y1 = y0 < maxY ? y0 + 1 : y0;
      final fx = u - x0, fy = v - y0;
      final i00 = (y0 * sw + x0) * 4;
      final i10 = (y0 * sw + x1) * 4;
      final i01 = (y1 * sw + x0) * 4;
      final i11 = (y1 * sw + x1) * 4;
      final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy, w11 = fx * fy;
      for (var k = 0; k < 3; k++) {
        out[o + k] = (sb[i00 + k] * w00 +
                sb[i10 + k] * w10 +
                sb[i01 + k] * w01 +
                sb[i11 + k] * w11 +
                0.5)
            .toInt();
      }
      out[o + 3] = 255;
      o += 4;
    }
  }
  return RawRgba(out, ow, oh);
}

/// Homographie, die Punkte [from] (Ziel-Rechteck) auf [to] (Quell-Viereck) abbildet.
List<double> _homography(List<double> from, List<double> to) {
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final x = from[i * 2], y = from[i * 2 + 1];
    final u = to[i * 2], v = to[i * 2 + 1];
    a[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
    a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
  }
  // Gauß mit Pivotsuche
  for (var col = 0; col < 8; col++) {
    var piv = col;
    for (var r = col + 1; r < 8; r++) {
      if (a[r][col].abs() > a[piv][col].abs()) piv = r;
    }
    final t = a[col];
    a[col] = a[piv];
    a[piv] = t;
    final p = a[col][col];
    if (p.abs() < 1e-12) return [1, 0, 0, 0, 1, 0, 0, 0];
    for (var k = col; k < 9; k++) {
      a[col][k] /= p;
    }
    for (var r = 0; r < 8; r++) {
      if (r == col) continue;
      final f = a[r][col];
      if (f == 0) continue;
      for (var k = col; k < 9; k++) {
        a[r][k] -= f * a[col][k];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) a[i][8]];
}

RawRgba _rotate(RawRgba s, int quarterTurns) {
  final q = ((quarterTurns % 4) + 4) % 4;
  if (q == 0) return s;
  final w = s.width, h = s.height;
  final nw = q.isOdd ? h : w;
  final nh = q.isOdd ? w : h;
  final px = s.bytes.buffer.asUint32List();
  final out = Uint32List(nw * nh);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int nx, ny;
      switch (q) {
        case 1:
          nx = h - 1 - y;
          ny = x;
        case 2:
          nx = w - 1 - x;
          ny = h - 1 - y;
        default:
          nx = y;
          ny = w - 1 - x;
      }
      out[ny * nw + nx] = px[y * w + x];
    }
  }
  return RawRgba(out.buffer.asUint8List(), nw, nh);
}

// ---------------------------------------------------------------------------
// Filter

void _applyFilter(RawRgba im, ScanFilter f, double brightness, double contrast) {
  final b = im.bytes;
  final n = im.width * im.height;
  final cf = math.pow(2.0, contrast * 1.3).toDouble();
  final bo = brightness * 90;

  int adj(double v) {
    final r = (v - 128) * cf + 128 + bo;
    return r < 0 ? 0 : (r > 255 ? 255 : r.toInt());
  }

  if (f == ScanFilter.original) {
    if (brightness == 0 && contrast == 0) return;
    final lut = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      lut[i] = adj(i.toDouble());
    }
    for (var j = 0; j < n * 4; j += 4) {
      b[j] = lut[b[j]];
      b[j + 1] = lut[b[j + 1]];
      b[j + 2] = lut[b[j + 2]];
    }
    return;
  }

  // Helligkeit (Luminanz)
  final lum = Uint8List(n);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    lum[i] = ((b[j] * 77 + b[j + 1] * 150 + b[j + 2] * 29) >> 8);
  }
  final bg = _background(lum, im.width, im.height);

  // Tonkurve: Papier wird weiß, Schrift satter – danach Helligkeit/Kontrast
  final lut = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    var x = ((i / 255.0) - 0.05) / 0.85;
    x = x.clamp(0.0, 1.0);
    x = math.pow(x, 1.25).toDouble();
    lut[i] = adj(x * 255);
  }
  int idx(double v) => v >= 255 ? 255 : (v <= 0 ? 0 : v.toInt());

  if (f == ScanFilter.enhanced) {
    for (var i = 0, j = 0; i < n; i++, j += 4) {
      final k = 255.0 / bg[i];
      var r = b[j] * k, g = b[j + 1] * k, bl = b[j + 2] * k;
      // leicht kräftigere Farben
      final l = (r * 0.3 + g * 0.59 + bl * 0.11);
      r = l + (r - l) * 1.3;
      g = l + (g - l) * 1.3;
      bl = l + (bl - l) * 1.3;
      b[j] = lut[idx(r)];
      b[j + 1] = lut[idx(g)];
      b[j + 2] = lut[idx(bl)];
    }
    return;
  }

  if (f == ScanFilter.gray) {
    for (var i = 0, j = 0; i < n; i++, j += 4) {
      final v = lut[idx(lum[i] * 255.0 / bg[i])];
      b[j] = v;
      b[j + 1] = v;
      b[j + 2] = v;
    }
    return;
  }

  // Schwarzweiß: Hintergrund ausgleichen, dann Schwelle
  final t = (205 - brightness * 70 + contrast * 25).clamp(60, 250).toDouble();
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    final v = lum[i] * 255.0 / bg[i];
    final o = v < t ? 0 : 255;
    b[j] = o;
    b[j + 1] = o;
    b[j + 2] = o;
  }
}

/// Schätzt die Papierhelligkeit je Pixel (für Schattenausgleich).
Uint8List _background(Uint8List lum, int w, int h) {
  final bs = math.max(8, math.max(w, h) ~/ 22);
  final gw = (w + bs - 1) ~/ bs, gh = (h + bs - 1) ~/ bs;
  final grid = Float64List(gw * gh);
  final step = math.max(1, bs ~/ 14);
  final hist = Int32List(256);
  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      hist.fillRange(0, 256, 0);
      var cnt = 0;
      final y1 = math.min(h, (gy + 1) * bs), x1 = math.min(w, (gx + 1) * bs);
      for (var y = gy * bs; y < y1; y += step) {
        for (var x = gx * bs; x < x1; x += step) {
          hist[lum[y * w + x]]++;
          cnt++;
        }
      }
      final target = (cnt * 0.9).floor();
      var acc = 0, v = 255;
      for (var i = 0; i < 256; i++) {
        acc += hist[i];
        if (acc > target) {
          v = i;
          break;
        }
      }
      grid[gy * gw + gx] = v.toDouble();
    }
  }
  // glätten
  final sm = Float64List(gw * gh);
  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      var s = 0.0, c = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final x = gx + dx, y = gy + dy;
          if (x < 0 || y < 0 || x >= gw || y >= gh) continue;
          s += grid[y * gw + x];
          c++;
        }
      }
      sm[gy * gw + gx] = math.max(60.0, s / c);
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    var fy = (y + 0.5) / bs - 0.5;
    if (fy < 0) fy = 0;
    if (fy > gh - 1) fy = (gh - 1).toDouble();
    final y0 = fy.floor(), y1 = math.min(gh - 1, y0 + 1);
    final ty = fy - y0;
    for (var x = 0; x < w; x++) {
      var fx = (x + 0.5) / bs - 0.5;
      if (fx < 0) fx = 0;
      if (fx > gw - 1) fx = (gw - 1).toDouble();
      final x0 = fx.floor(), x1 = math.min(gw - 1, x0 + 1);
      final tx = fx - x0;
      final v = (sm[y0 * gw + x0] * (1 - tx) + sm[y0 * gw + x1] * tx) * (1 - ty) +
          (sm[y1 * gw + x0] * (1 - tx) + sm[y1 * gw + x1] * tx) * ty;
      out[y * w + x] = v.round().clamp(60, 255);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Automatische Kantenerkennung

/// Sucht das Dokument im Bild. Liefert 8 normierte Werte (Ecken TL,TR,BR,BL)
/// oder null, wenn nichts Sinnvolles gefunden wurde.
List<double>? detectDocument(RawRgba src) {
  const target = 220;
  final s = math.max(src.width, src.height) / target;
  final w = math.max(8, (src.width / s).floor());
  final h = math.max(8, (src.height / s).floor());
  final g = Float64List(w * h);
  final sb = src.bytes;
  // verkleinern (Mittelwert über Stichproben)
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var acc = 0.0, c = 0;
      for (var dy = 0; dy < 3; dy++) {
        for (var dx = 0; dx < 3; dx++) {
          final sx = math.min(src.width - 1, ((x + dx / 3) * s).floor());
          final sy = math.min(src.height - 1, ((y + dy / 3) * s).floor());
          final i = (sy * src.width + sx) * 4;
          // Papier ist hell und wenig gesättigt
          final r = sb[i], gg = sb[i + 1], b = sb[i + 2];
          final mx = math.max(r, math.max(gg, b)), mn = math.min(r, math.min(gg, b));
          acc += (r * 0.3 + gg * 0.59 + b * 0.11) - (mx - mn) * 0.5;
          c++;
        }
      }
      g[y * w + x] = acc / c;
    }
  }
  // Otsu-Schwelle
  final hist = List<int>.filled(256, 0);
  for (final v in g) {
    hist[v.clamp(0, 255).toInt()]++;
  }
  final total = g.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, thr = 128;
  for (var i = 0; i < 256; i++) {
    wB += hist[i];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += i * hist[i];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      thr = i;
    }
  }
  final mask = Uint8List(w * h);
  for (var i = 0; i < mask.length; i++) {
    mask[i] = g[i] > thr ? 1 : 0;
  }
  // größte zusammenhängende helle Fläche
  final label = Int32List(w * h);
  var bestLabel = 0, bestSize = 0, cur = 0;
  final stack = <int>[];
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] == 0 || label[i] != 0) continue;
    cur++;
    var size = 0;
    stack.add(i);
    label[i] = cur;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      size++;
      final px = p % w, py = p ~/ w;
      void visit(int q) {
        if (mask[q] == 1 && label[q] == 0) {
          label[q] = cur;
          stack.add(q);
        }
      }

      if (px > 0) visit(p - 1);
      if (px < w - 1) visit(p + 1);
      if (py > 0) visit(p - w);
      if (py < h - 1) visit(p + w);
    }
    if (size > bestSize) {
      bestSize = size;
      bestLabel = cur;
    }
  }
  if (bestSize < total * 0.12 || bestSize > total * 0.985) return null;

  double tlv = double.infinity, brv = -double.infinity;
  double trv = -double.infinity, blv = double.infinity;
  var tl = const math.Point(0, 0), br = const math.Point(0, 0);
  var tr = const math.Point(0, 0), bl = const math.Point(0, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (label[y * w + x] != bestLabel) continue;
      final a = x + y, d = x - y;
      if (a < tlv) {
        tlv = a.toDouble();
        tl = math.Point(x, y);
      }
      if (a > brv) {
        brv = a.toDouble();
        br = math.Point(x, y);
      }
      if (d > trv) {
        trv = d.toDouble();
        tr = math.Point(x, y);
      }
      if (d < blv) {
        blv = d.toDouble();
        bl = math.Point(x, y);
      }
    }
  }
  final res = <double>[];
  for (final p in [tl, tr, br, bl]) {
    res.add(((p.x + 0.5) / w).clamp(0.0, 1.0));
    res.add(((p.y + 0.5) / h).clamp(0.0, 1.0));
  }
  // Plausibilität: Fläche des Vierecks
  final area = _quadArea(res);
  if (area < 0.1) return null;
  return res;
}

double _quadArea(List<double> c) {
  var a = 0.0;
  for (var i = 0; i < 4; i++) {
    final j = (i + 1) % 4;
    a += c[i * 2] * c[j * 2 + 1] - c[j * 2] * c[i * 2 + 1];
  }
  return a.abs() / 2;
}

const defaultCorners = <double>[0.04, 0.04, 0.96, 0.04, 0.96, 0.96, 0.04, 0.96];
const fullCorners = <double>[0, 0, 1, 0, 1, 1, 0, 1];
