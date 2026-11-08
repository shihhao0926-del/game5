Add-Type -AssemblyName System.Drawing

$assetsDir = Join-Path (Get-Location).Path "assets"
if (!(Test-Path $assetsDir)) {
    New-Item -ItemType Directory -Path $assetsDir | Out-Null
}

# Pure .NET PNG encoder from Bitmap raw pixels (bypasses GDI+ Save codec restriction in sandbox)
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Compression;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class PngWriter {
    private static uint[] crcTable;
    static PngWriter() {
        crcTable = new uint[256];
        for (uint n = 0; n < 256; n++) {
            uint c = n;
            for (int k = 0; k < 8; k++) {
                c = ((c & 1) != 0) ? (0xedb88320U ^ (c >> 1)) : (c >> 1);
            }
            crcTable[n] = c;
        }
    }

    private static uint Crc32(byte[] buf, int offset, int len, uint crc = 0xffffffffU) {
        for (int i = 0; i < len; i++) {
            crc = crcTable[(crc ^ buf[offset + i]) & 0xff] ^ (crc >> 8);
        }
        return crc ^ 0xffffffffU;
    }

    private static void WriteUInt32BE(Stream s, uint val) {
        s.WriteByte((byte)(val >> 24));
        s.WriteByte((byte)(val >> 16));
        s.WriteByte((byte)(val >> 8));
        s.WriteByte((byte)val);
    }

    private static void WriteChunk(Stream s, string type, byte[] data) {
        WriteUInt32BE(s, (uint)data.Length);
        byte[] typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        s.Write(typeBytes, 0, 4);
        if (data.Length > 0) s.Write(data, 0, data.Length);
        byte[] crcBuf = new byte[4 + data.Length];
        Buffer.BlockCopy(typeBytes, 0, crcBuf, 0, 4);
        Buffer.BlockCopy(data, 0, crcBuf, 4, data.Length);
        WriteUInt32BE(s, Crc32(crcBuf, 0, crcBuf.Length));
    }

    public static void SaveRgbaPng(Bitmap bmp, string path) {
        int w = bmp.Width;
        int h = bmp.Height;
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] raw = new byte[bd.Stride * h];
        Marshal.Copy(bd.Scan0, raw, 0, raw.Length);
        bmp.UnlockBits(bd);

        // Convert BGRA to RGBA with filter byte 0 per row
        byte[] scanlines = new byte[h * (w * 4 + 1)];
        int dst = 0;
        for (int y = 0; y < h; y++) {
            scanlines[dst++] = 0; // Filter type 0 (None)
            int rowStart = y * bd.Stride;
            for (int x = 0; x < w; x++) {
                int p = rowStart + x * 4;
                scanlines[dst++] = raw[p + 2]; // R
                scanlines[dst++] = raw[p + 1]; // G
                scanlines[dst++] = raw[p + 0]; // B
                scanlines[dst++] = raw[p + 3]; // A
            }
        }

        byte[] idatBytes;
        using (MemoryStream msZlib = new MemoryStream()) {
            msZlib.WriteByte(0x78);
            msZlib.WriteByte(0x9C);
            using (DeflateStream ds = new DeflateStream(msZlib, CompressionMode.Compress, true)) {
                ds.Write(scanlines, 0, scanlines.Length);
            }
            // Adler-32 checksum
            uint s1 = 1, s2 = 0;
            for (int i = 0; i < scanlines.Length; i++) {
                s1 = (s1 + scanlines[i]) % 65521;
                s2 = (s2 + s1) % 65521;
            }
            uint adler = (s2 << 16) | s1;
            WriteUInt32BE(msZlib, adler);
            idatBytes = msZlib.ToArray();
        }

        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write)) {
            byte[] sig = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
            fs.Write(sig, 0, 8);

            using (MemoryStream ihdr = new MemoryStream()) {
                WriteUInt32BE(ihdr, (uint)w);
                WriteUInt32BE(ihdr, (uint)h);
                ihdr.WriteByte(8); // bit depth
                ihdr.WriteByte(6); // color type RGBA
                ihdr.WriteByte(0); // compression
                ihdr.WriteByte(0); // filter
                ihdr.WriteByte(0); // interlace
                WriteChunk(fs, "IHDR", ihdr.ToArray());
            }
            WriteChunk(fs, "IDAT", idatBytes);
            WriteChunk(fs, "IEND", new byte[0]);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing

function Save-PngBitmap($bmp, [string]$filePath) {
    [PngWriter]::SaveRgbaPng($bmp, $filePath)
}

function New-StarPolygon([float]$cx, [float]$cy, [float]$outerR, [float]$innerR, [int]$points, [float]$angleOffset = 0) {
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    $step = [Math]::PI / $points
    for ($i = 0; $i -lt ($points * 2); $i++) {
        $r = if ($i % 2 -eq 0) { $outerR } else { $innerR }
        $a = $i * $step - ([Math]::PI / 2) + $angleOffset
        $x = $cx + [float]([Math]::Cos($a) * $r)
        $y = $cy + [float]([Math]::Sin($a) * $r)
        $pts.Add((New-Object System.Drawing.PointF($x, $y)))
    }
    return [System.Drawing.PointF[]]$pts.ToArray()
}

function Draw-GlowCircle($g, [float]$cx, [float]$cy, [float]$radius, [System.Drawing.Color]$centerColor, [System.Drawing.Color]$edgeColor) {
    if ($radius -le 2) { return }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse([float]($cx - $radius), [float]($cy - $radius), [float]($radius * 2), [float]($radius * 2))
    $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $pgb.CenterColor = $centerColor
    $pgb.SurroundColors = [System.Drawing.Color[]]@($edgeColor)
    $g.FillPath($pgb, $path)
    $pgb.Dispose()
    $path.Dispose()
}

$frameSize = 160
$frames = 8
$sheetWidth = $frameSize * $frames
$sheetHeight = $frameSize

# 1. Fire Sprite Sheet (fx_fire_sprite.png)
$bmpFire = New-Object System.Drawing.Bitmap($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gFire = [System.Drawing.Graphics]::FromImage($bmpFire)
$gFire.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gFire.Clear([System.Drawing.Color]::Transparent)

for ($f = 0; $f -lt $frames; $f++) {
    $cx = [float]($f * $frameSize + 80)
    $cy = [float]80
    $alpha = if ($f -lt 6) { 240 } else { [int](240 * (1.0 - ($f - 5) * 0.32)) }

    $rOuter = [float](22 + $f * 7.5)
    Draw-GlowCircle $gFire $cx $cy $rOuter ([System.Drawing.Color]::FromArgb($alpha, 255, 95, 20)) ([System.Drawing.Color]::FromArgb(0, 255, 30, 0))

    $starPts = New-StarPolygon $cx $cy ($rOuter * 0.85) ($rOuter * 0.42) 8 ($f * 0.35)
    $brushFlame = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int]($alpha * 0.88), 255, 165, 0))
    $gFire.FillPolygon($brushFlame, $starPts)
    $brushFlame.Dispose()

    $rCore = [float][Math]::Max(6, 32 - $f * 2.5)
    Draw-GlowCircle $gFire $cx $cy $rCore ([System.Drawing.Color]::FromArgb($alpha, 255, 255, 220)) ([System.Drawing.Color]::FromArgb(0, 255, 200, 0))

    for ($p = 0; $p -lt 6; $p++) {
        $ang = ($p * 1.047) + ($f * 0.28)
        $dist = 14 + $f * 7.2
        $px = $cx + [float]([Math]::Cos($ang) * $dist)
        $py = $cy + [float]([Math]::Sin($ang) * $dist)
        $miniStar = New-StarPolygon $px $py ([float](9 - $f * 0.6)) ([float](4 - $f * 0.3)) 4 ($f * 0.4)
        $bSpark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 254, 240, 138))
        $gFire.FillPolygon($bSpark, $miniStar)
        $bSpark.Dispose()
    }
}
Save-PngBitmap $bmpFire (Join-Path $assetsDir "fx_fire_sprite.png")
$gFire.Dispose()
$bmpFire.Dispose()

# 2. Meteor & Chrono Slash Sprite Sheet (fx_meteor_sprite.png)
$bmpMeteor = New-Object System.Drawing.Bitmap($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gMeteor = [System.Drawing.Graphics]::FromImage($bmpMeteor)
$gMeteor.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gMeteor.Clear([System.Drawing.Color]::Transparent)

for ($f = 0; $f -lt $frames; $f++) {
    $cx = [float]($f * $frameSize + 80)
    $cy = [float]80
    $alpha = if ($f -lt 6) { 245 } else { [int](245 * (1.0 - ($f - 5) * 0.32)) }

    $rAura = [float](26 + $f * 7)
    Draw-GlowCircle $gMeteor $cx $cy $rAura ([System.Drawing.Color]::FromArgb($alpha, 192, 132, 252)) ([System.Drawing.Color]::FromArgb(0, 88, 28, 135))

    $slashLen = [float](28 + $f * 6.5)
    $slashPts = New-StarPolygon $cx $cy $slashLen ($slashLen * 0.22) 4 ($f * 0.25)
    $bSlash = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 244, 114, 182))
    $gMeteor.FillPolygon($bSlash, $slashPts)
    $bSlash.Dispose()

    $innerPts = New-StarPolygon $cx $cy ($slashLen * 0.72) ($slashLen * 0.16) 4 ($f * 0.25 + 0.785)
    $bInner = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 254, 240, 138))
    $gMeteor.FillPolygon($bInner, $innerPts)
    $bInner.Dispose()

    $penRing = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 56, 189, 248), [float]3.0)
    $ringR = [float](16 + $f * 5.5)
    $gMeteor.DrawEllipse($penRing, [float]($cx - $ringR), [float]($cy - $ringR), [float]($ringR * 2), [float]($ringR * 2))
    $penRing.Dispose()
}
Save-PngBitmap $bmpMeteor (Join-Path $assetsDir "fx_meteor_sprite.png")
$gMeteor.Dispose()
$bmpMeteor.Dispose()

# 3. Thunder Shield-Break Sprite Sheet (fx_thunder_sprite.png)
$bmpThunder = New-Object System.Drawing.Bitmap($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gThunder = [System.Drawing.Graphics]::FromImage($bmpThunder)
$gThunder.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gThunder.Clear([System.Drawing.Color]::Transparent)

for ($f = 0; $f -lt $frames; $f++) {
    $cx = [float]($f * $frameSize + 80)
    $cy = [float]80
    $alpha = if ($f -lt 6) { 250 } else { [int](250 * (1.0 - ($f - 5) * 0.32)) }

    $rGlow = [float](24 + $f * 6.8)
    Draw-GlowCircle $gThunder $cx $cy $rGlow ([System.Drawing.Color]::FromArgb($alpha, 56, 189, 248)) ([System.Drawing.Color]::FromArgb(0, 2, 132, 199))

    $penBoltOuter = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 250, 204, 21), [float]7.0)
    $penBoltInner = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 255, 255, 255), [float]3.0)
    $jitter = ($f % 2) * 8 - 4
    $boltPts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF([float]($cx - 10 + $jitter), [float]14)),
        (New-Object System.Drawing.PointF([float]($cx + 14 - $jitter), [float]54)),
        (New-Object System.Drawing.PointF([float]($cx - 6 + $jitter), [float]68)),
        (New-Object System.Drawing.PointF([float]($cx + 18 - $jitter), [float]112)),
        (New-Object System.Drawing.PointF([float]($cx - 4 + $jitter), [float]146))
    )
    $gThunder.DrawLines($penBoltOuter, $boltPts)
    $gThunder.DrawLines($penBoltInner, $boltPts)
    $penBoltOuter.Dispose()
    $penBoltInner.Dispose()

    $spikeStar = New-StarPolygon $cx $cy ([float](20 + $f * 6)) ([float](10 + $f * 2.5)) 10 ($f * 0.2)
    $penSpike = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 254, 240, 138), [float]2.5)
    $gThunder.DrawPolygon($penSpike, $spikeStar)
    $penSpike.Dispose()
}
Save-PngBitmap $bmpThunder (Join-Path $assetsDir "fx_thunder_sprite.png")
$gThunder.Dispose()
$bmpThunder.Dispose()

# 4. Geometric Shield Barrier Sprite Sheet (fx_shield_sprite.png)
$bmpShield = New-Object System.Drawing.Bitmap($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gShield = [System.Drawing.Graphics]::FromImage($bmpShield)
$gShield.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gShield.Clear([System.Drawing.Color]::Transparent)

for ($f = 0; $f -lt $frames; $f++) {
    $cx = [float]($f * $frameSize + 80)
    $cy = [float]80
    $alpha = if ($f -lt 6) { 235 } else { [int](235 * (1.0 - ($f - 5) * 0.3)) }
    $r = [float](26 + [Math]::Min($f, 5) * 7.5)

    Draw-GlowCircle $gShield $cx $cy ($r * 1.15) ([System.Drawing.Color]::FromArgb([int]($alpha * 0.65), 56, 189, 248)) ([System.Drawing.Color]::FromArgb(0, 14, 165, 233))

    $penCircle = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 125, 211, 252), [float]3.5)
    $gShield.DrawEllipse($penCircle, [float]($cx - $r), [float]($cy - $r), [float]($r * 2), [float]($r * 2))
    $penCircle.Dispose()

    $tri1 = New-StarPolygon $cx $cy $r ($r * 0.5) 3 ($f * 0.26)
    $tri2 = New-StarPolygon $cx $cy $r ($r * 0.5) 3 (-$f * 0.26 + 1.047)
    $penTri1 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 250, 204, 21), [float]3.0)
    $penTri2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 244, 114, 182), [float]2.5)
    $gShield.DrawPolygon($penTri1, $tri1)
    $gShield.DrawPolygon($penTri2, $tri2)
    $penTri1.Dispose()
    $penTri2.Dispose()
}
Save-PngBitmap $bmpShield (Join-Path $assetsDir "fx_shield_sprite.png")
$gShield.Dispose()
$bmpShield.Dispose()

# 5. Starlight Heal & Mana Spring Sprite Sheet (fx_heal_sprite.png)
$bmpHeal = New-Object System.Drawing.Bitmap($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gHeal = [System.Drawing.Graphics]::FromImage($bmpHeal)
$gHeal.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gHeal.Clear([System.Drawing.Color]::Transparent)

for ($f = 0; $f -lt $frames; $f++) {
    $cx = [float]($f * $frameSize + 80)
    $cy = [float]80
    $alpha = if ($f -lt 6) { 240 } else { [int](240 * (1.0 - ($f - 5) * 0.3)) }
    $r = [float](25 + $f * 6.5)

    Draw-GlowCircle $gHeal $cx $cy $r ([System.Drawing.Color]::FromArgb([int]($alpha * 0.75), 52, 211, 153)) ([System.Drawing.Color]::FromArgb(0, 16, 185, 129))

    for ($i = 0; $i -lt 5; $i++) {
        $sx = [float]($cx + (($i - 2) * 20))
        $sy = [float]($cy + 30 - ($f * 9) - (($i % 2) * 14))
        $star = New-StarPolygon $sx $sy 11 4.5 4 ($f * 0.3)
        $bStar = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 254, 240, 138))
        $gHeal.FillPolygon($bStar, $star)
        $bStar.Dispose()
    }

    $penRing = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($alpha, 167, 243, 208), [float]3.0)
    $gHeal.DrawEllipse($penRing, [float]($cx - $r * 0.8), [float]($cy - $r * 0.4), [float]($r * 1.6), [float]($r * 0.8))
    $penRing.Dispose()
}
Save-PngBitmap $bmpHeal (Join-Path $assetsDir "fx_heal_sprite.png")
$gHeal.Dispose()
$bmpHeal.Dispose()

Write-Output "ALL_5_SPRITES_SAVED_OK"
