#!/bin/sh
# ==============================================================================
#  AI VIDEO KLIP V4 — install.sh untuk OpenWrt  (SATU FILE, SEMUA ISI)
#
#  Satu file ini sudah memuat: app.py, templates/index.html, script start,
#  service procd (auto-start saat boot), dan pembuat folder di /mnt/sda1.
#
#  Cara pakai (di router, lewat SSH, sebagai root):
#    wget -O /tmp/install.sh https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh
#    sh /tmp/install.sh
#
#  Opsi (environment variable, opsional):
#    GEMINI_API_KEY=xxxx   langsung isi API key tanpa prompt
#    AIVK_DIR=/mnt/sda1/ai-video-klip   lokasi instalasi + data
#    AIVK_MOUNT=/mnt/sda1               mount point yang wajib aktif
#    AIVK_PORT=5000                     port web
#
#  Perintah lain:
#    sh install.sh uninstall    hapus service (data video/klip TIDAK dihapus)
#    Jalankan ulang install.sh  = update aplikasi (.env, video, klip tetap aman)
# ==============================================================================

INSTALL_DIR="${AIVK_DIR:-/mnt/sda1/ai-video-klip}"
MOUNT_POINT="${AIVK_MOUNT:-/mnt/sda1}"
PORT="${AIVK_PORT:-5000}"
SERVICE="ai-video-klip"
STEP=""

say()  { echo "▶ $*"; }
warn() { echo "⚠️  $*"; }
die() {
    echo ""
    echo "❌ GAGAL pada tahap: $STEP"
    [ -n "${1:-}" ] && echo "   $1"
    echo "   Perbaiki penyebabnya lalu jalankan ulang: sh install.sh"
    exit 1
}

echo "🎬 AI Video Klip V4 — Installer OpenWrt"
echo "========================================"

# ---------- uninstall ----------
if [ "${1:-}" = "uninstall" ]; then
    [ -x "/etc/init.d/$SERVICE" ] && { "/etc/init.d/$SERVICE" stop; "/etc/init.d/$SERVICE" disable; }
    rm -f "/etc/init.d/$SERVICE"
    echo "✓ Service dihapus."
    echo "  Kode & data masih ada di: $INSTALL_DIR"
    echo "  Kalau mau hapus total: rm -rf $INSTALL_DIR"
    exit 0
fi

# ---------- cek dasar ----------
STEP="cek root"
[ "$(id -u)" = "0" ] || die "Jalankan sebagai root."
[ -f /etc/openwrt_release ] || warn "Ini sepertinya bukan OpenWrt — lanjut, tapi tidak dijamin jalan."

STEP="deteksi package manager"
if command -v opkg >/dev/null 2>&1; then
    PM=opkg
elif command -v apk >/dev/null 2>&1; then
    PM=apk
else
    die "opkg / apk tidak ditemukan."
fi
say "Package manager: $PM"

pm_update()  { if [ "$PM" = opkg ]; then opkg update; else apk update; fi; }
pm_install() { if [ "$PM" = opkg ]; then opkg install "$@"; else apk add "$@"; fi; }

# ---------- cek storage /mnt/sda1 ----------
STEP="cek storage $MOUNT_POINT"
is_mounted() { grep -q " $MOUNT_POINT " /proc/mounts 2>/dev/null; }
if ! is_mounted; then
    command -v block >/dev/null 2>&1 && block mount >/dev/null 2>&1
    sleep 2
fi
if ! is_mounted; then
    if [ "${AIVK_ALLOW_UNMOUNTED:-0}" != "1" ]; then
        echo "   $MOUNT_POINT belum ter-mount. Kalau dibiarkan, video akan menumpuk di flash router."
        echo "   Cek: ls /dev/sd*   dan   block info"
        echo "   Biasanya perlu paket: kmod-usb-storage block-mount + kmod-fs-ext4 (atau kmod-fs-exfat / kmod-fs-ntfs3)"
        echo "   lalu atur di LuCI: System > Mount Points (mount ke $MOUNT_POINT), kemudian: block mount"
        die "Storage belum siap."
    fi
    warn "Storage belum ter-mount, dilanjutkan karena AIVK_ALLOW_UNMOUNTED=1"
fi
mkdir -p "$INSTALL_DIR" 2>/dev/null || die "Tidak bisa membuat $INSTALL_DIR"
touch "$INSTALL_DIR/.write_test" 2>/dev/null || die "$INSTALL_DIR tidak bisa ditulis (read-only?)"
rm -f "$INSTALL_DIR/.write_test"
say "Storage OK: $(df -h "$MOUNT_POINT" 2>/dev/null | awk 'NR==2{print $4" kosong dari "$2}')"

# ---------- buat folder ----------
STEP="membuat folder"
for d in downloads clips uploads_srt uploads_music templates fonts bin pylibs tmp cache; do
    mkdir -p "$INSTALL_DIR/$d" || die "Gagal membuat $INSTALL_DIR/$d"
done
say "Folder dibuat di $INSTALL_DIR  (downloads, clips, uploads_srt, uploads_music, ...)"

# Semua file sementara (pip, unduhan) ke storage, bukan ke RAM /tmp
export TMPDIR="$INSTALL_DIR/tmp"
export PATH="$INSTALL_DIR/bin:$PATH"
export PYTHONPATH="$INSTALL_DIR/pylibs${PYTHONPATH:+:$PYTHONPATH}"

OVL_FREE="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$OVL_FREE" ] && [ "$OVL_FREE" -lt 40000 ] 2>/dev/null && \
    warn "Flash/overlay tinggal $((OVL_FREE/1024)) MB. Python + ffmpeg butuh lumayan besar; kalau gagal, pakai extroot."

# ---------- paket sistem ----------
STEP="update daftar paket ($PM update)"
pm_update || die "Router harus online. Cek koneksi internet & DNS."

STEP="install paket sistem"
say "Memasang paket (python3, ffmpeg, dll) — bisa beberapa menit..."
FAILED=""
for p in ca-bundle ca-certificates curl python3 python3-pip python3-flask python3-requests ffmpeg; do
    pm_install "$p" >/dev/null 2>&1 || {
        # coba sekali lagi dengan output kelihatan supaya penyebab jelas
        pm_install "$p" 2>&1 | tail -n 3
        pm_install "$p" >/dev/null 2>&1 || FAILED="$FAILED $p"
    }
done
[ -n "$FAILED" ] && warn "Paket gagal dipasang lewat $PM:$FAILED (akan dicek / dicari alternatif di bawah)"

fetch() {  # fetch URL OUTPUT
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

# ---------- Python & library ----------
STEP="cek python3"
command -v python3 >/dev/null 2>&1 || die "python3 tidak terpasang (kemungkinan flash penuh)."

STEP="cek modul ssl python"
if ! python3 -c "import ssl" 2>/dev/null; then
    pm_install python3-openssl >/dev/null 2>&1
    python3 -c "import ssl" 2>/dev/null || die "Modul ssl Python tidak tersedia."
fi

STEP="install Flask & requests"
if ! python3 -c "import flask, requests" 2>/dev/null; then
    say "Flask/requests belum ada lewat $PM, pasang lewat pip ke $INSTALL_DIR/pylibs"
    python3 -m pip install --no-cache-dir --target "$INSTALL_DIR/pylibs" flask requests \
        || die "pip gagal memasang Flask/requests."
fi
python3 -c "import flask, requests" 2>/dev/null || die "Flask/requests masih tidak bisa di-import."

STEP="install yt-dlp"
say "Memasang yt-dlp (ke $INSTALL_DIR/pylibs)..."
python3 -m pip install --no-cache-dir --upgrade --target "$INSTALL_DIR/pylibs" yt-dlp \
    || die "pip gagal memasang yt-dlp (python3-pip terpasang? internet jalan?)."

cat > "$INSTALL_DIR/bin/yt-dlp" <<'AIVK_EOF_YTDLP'
#!/bin/sh
D="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$D/pylibs${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m yt_dlp "$@"
AIVK_EOF_YTDLP
chmod +x "$INSTALL_DIR/bin/yt-dlp" 2>/dev/null
"$INSTALL_DIR/bin/yt-dlp" --version >/dev/null 2>&1 || die "yt-dlp terpasang tapi tidak bisa dijalankan."
say "yt-dlp versi $("$INSTALL_DIR/bin/yt-dlp" --version 2>/dev/null)"

# ---------- ffmpeg: pastikan fiturnya lengkap ----------
STEP="cek fitur ffmpeg"
ff_ok() {
    command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || return 1
    ENC="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
    FLT="$(ffmpeg -hide_banner -filters 2>/dev/null)"
    echo "$ENC" | grep -q "libx264" || return 1
    echo "$ENC" | grep -qE " aac " || return 1
    for f in subtitles eq fade silencedetect aselect amix crop select; do
        echo "$FLT" | grep -qE " $f " || return 1
    done
    return 0
}

if ff_ok; then
    say "ffmpeg dari $PM sudah lengkap (libx264, aac, subtitles/libass, dst)."
else
    warn "ffmpeg dari $PM kurang fitur (butuh libx264 + filter subtitles/libass). Pakai build static."
    case "$(uname -m)" in
        x86_64)          FFARCH="amd64" ;;
        aarch64|arm64)   FFARCH="arm64" ;;
        armv7*|armhf)    FFARCH="armhf" ;;
        armv6*|arm)      FFARCH="armel" ;;
        i?86)            FFARCH="i686" ;;
        *)               FFARCH="" ;;
    esac
    [ -n "$FFARCH" ] || die "Arsitektur $(uname -m) tidak punya build ffmpeg static otomatis. Pasang 'ffmpeg-full' / build sendiri."
    pm_install xz xz-utils tar >/dev/null 2>&1
    command -v xz >/dev/null 2>&1 || die "Perintah xz tidak ada (pasang paket xz / xz-utils)."
    STEP="unduh ffmpeg static ($FFARCH)"
    FFTMP="$INSTALL_DIR/tmp/ffmpeg-static"
    rm -rf "$FFTMP"; mkdir -p "$FFTMP"
    fetch "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-$FFARCH-static.tar.xz" "$FFTMP/ff.tar.xz" \
        || die "Gagal mengunduh ffmpeg static."
    xz -dc "$FFTMP/ff.tar.xz" | tar -xf - -C "$FFTMP" || die "Gagal ekstrak ffmpeg static."
    FFBIN="$(find "$FFTMP" -type f -name ffmpeg  | head -n 1)"
    FPBIN="$(find "$FFTMP" -type f -name ffprobe | head -n 1)"
    [ -n "$FFBIN" ] && [ -n "$FPBIN" ] || die "ffmpeg/ffprobe tidak ditemukan di arsip."
    cp "$FFBIN" "$INSTALL_DIR/bin/ffmpeg" && cp "$FPBIN" "$INSTALL_DIR/bin/ffprobe" || die "Gagal menyalin ffmpeg."
    chmod +x "$INSTALL_DIR/bin/ffmpeg" "$INSTALL_DIR/bin/ffprobe" 2>/dev/null
    rm -rf "$FFTMP"
    hash -r 2>/dev/null
    STEP="verifikasi ffmpeg static"
    ff_ok || die "ffmpeg static terpasang tapi tidak lolos pengecekan fitur."
    say "ffmpeg static terpasang di $INSTALL_DIR/bin"
fi

# ---------- font subtitle ----------
STEP="unduh font subtitle"
FONT_BASE="https://raw.githubusercontent.com/dejavu-fonts/dejavu-fonts/version_2_37/ttf"
FONT_OK=0
for f in DejaVuSans-Bold.ttf DejaVuSans.ttf; do
    if [ ! -s "$INSTALL_DIR/fonts/$f" ]; then
        fetch "$FONT_BASE/$f" "$INSTALL_DIR/fonts/$f" 2>/dev/null || rm -f "$INSTALL_DIR/fonts/$f"
    fi
    [ -s "$INSTALL_DIR/fonts/$f" ] && FONT_OK=1
done
if [ "$FONT_OK" = "1" ]; then
    say "Font subtitle: DejaVu Sans"
else
    warn "Font gagal diunduh. Taruh file .ttf apa saja di $INSTALL_DIR/fonts/ lalu isi AIVK_FONT_NAME=<nama font> di .env, kalau tidak subtitle bisa gagal."
fi

# ---------- tulis file aplikasi ----------
STEP="menulis app.py"
cat > "$INSTALL_DIR/app.py" <<'AIVK_EOF_APP'
# ============================================================
#  AI VIDEO KLIP V4 — app.py
#  Perubahan dari v3: model Gemini auto-fallback (2.5-flash akan
#  dimatikan Google Okt 2026), API key bisa lewat .env, guard biar
#  tidak ada 2 proses berat (download/potong) jalan bersamaan,
#  timeout ffmpeg mengikuti durasi klip, parser hasil Gemini lebih
#  toleran, dan cek dependency (ffmpeg/ffprobe/yt-dlp) saat start.
# ============================================================

import os
import json
import uuid
import re
import shutil
import subprocess
import threading
import requests as http_requests
from flask import Flask, render_template, request, jsonify, send_from_directory, send_file, url_for

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
# OpenWrt: semua data (video, klip, srt, musik, state) disimpan di storage USB/HDD
DATA_DIR = os.environ.get('AIVK_DATA_DIR') or '/mnt/sda1/ai-video-klip'

def load_dotenv(path):
    """Parser .env sederhana (tanpa dependency tambahan)."""
    env = {}
    if os.path.isfile(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#') or '=' not in line:
                        continue
                    k, v = line.split('=', 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
        except Exception as e:
            print('[.env] Gagal baca: ' + str(e))
    return env

_DOTENV = load_dotenv(os.path.join(BASE_DIR, '.env'))

def env_or(key, default):
    return os.environ.get(key) or _DOTENV.get(key) or default

# ============================================================
#  🔧 HARDCODE CONFIG — EDIT DI SINI SAJA
#  GEMINI_API_KEY sebaiknya diisi lewat file .env (dibuat otomatis
#  oleh install.sh) supaya tidak ke-commit ke Git. Nilai di bawah ini
#  cuma fallback kalau .env / env var tidak ada.
# ============================================================
CONFIG = {
    'GEMINI_API_KEY': env_or('GEMINI_API_KEY', ''),
    # Model utama dicoba dulu, kalau Google mematikan/mengganti nama modelnya
    # (404 NOT_FOUND), otomatis lanjut ke kandidat berikutnya — jadi app tidak
    # rusak total saat Google pensiunkan satu model generasi.
    'GEMINI_MODEL_CANDIDATES': [
        'gemini-flash-latest',
        'gemini-3.6-flash',
        'gemini-2.5-flash',
    ],
    'AUTO_EDIT':       True,
    'AUTO_JUMPCUT':    True,
    'JUMPCUT_NOISE_DB': -30,
    'JUMPCUT_MIN_SILENCE': 0.6,
    'JUMPCUT_PAD':     0.2,
    'OUTPUT_PROFILE': 'main',
    'OUTPUT_LEVEL':   '4.1',
    'AUDIO_BITRATE':  '192k',
    'BGM_VOLUME':     0.5,
    'FFMPEG_TIMEOUT': 900,
    'SUB_FONT':      env_or('AIVK_FONT_NAME', 'DejaVu Sans'),
    'SUB_FONT_RATIO': 0.042,
    'SUB_MARGIN_RATIO': 0.085,
    'SUB_MARGIN_LR_RATIO': 0.06,
    'SUB_OUTLINE_RATIO': 0.0025,
    'SUB_SHADOW':    1,
    'YT_LANG_PRIORITY': ['id-orig', 'id', 'en'],
    'YT_MAX_VTT_CHARS': 500000,
    'YT_DOWNLOAD_FORMAT': 'bv*[height=1080]+ba/b[height=1080]/bv*[height<=1080]+ba/b[height<=1080]/b',
    'YT_DOWNLOAD_THREADS': '16',
}

DOWNLOAD_DIR = os.path.join(DATA_DIR, 'downloads')
CLIP_DIR     = os.path.join(DATA_DIR, 'clips')
SRT_DIR      = os.path.join(DATA_DIR, 'uploads_srt')
MUSIC_DIR    = os.path.join(DATA_DIR, 'uploads_music')
STATE_FILE   = os.path.join(DATA_DIR, 'state.json')

for d in (DOWNLOAD_DIR, CLIP_DIR, SRT_DIR, MUSIC_DIR):
    os.makedirs(d, exist_ok=True)

GEMINI_API_KEY        = CONFIG['GEMINI_API_KEY']
GEMINI_MODEL_CANDIDATES = CONFIG['GEMINI_MODEL_CANDIDATES']
AUTO_EDIT          = CONFIG['AUTO_EDIT']
AUTO_JUMPCUT       = CONFIG['AUTO_JUMPCUT']
JUMPCUT_NOISE_DB   = CONFIG['JUMPCUT_NOISE_DB']
JUMPCUT_MIN_SILENCE= CONFIG['JUMPCUT_MIN_SILENCE']
JUMPCUT_PAD        = CONFIG['JUMPCUT_PAD']

GEMINI_PROMPT = """Anda adalah editor video profesional dengan 15 tahun pengalaman mengedit konten viral untuk Shorts/Reels/TikTok.

Saya akan memberikan transkrip video dalam format SRT. Analisis seluruh isi transkrip ini dan identifikasi momen-momen terbaik untuk dijadikan klip viral.

⚠️ ATURAN PALING UTAMA (WAJIB DIPATUHI, PRIORITAS DI ATAS SEGALANYA):
Klip HARUS mengikuti pembahasan/topik yang sedang dibicarakan sampai benar-benar SELESAI. DILARANG KERAS memotong atau mengakhiri klip sebelum topik itu tuntas dibahas — apapun alasannya, termasuk supaya durasi terlihat pas, ringkas, atau seragam dengan klip lain. Kalau di satu titik pembahasan belum kelar, klip WAJIB dilanjutkan sampai topik itu betul-betul selesai, meskipun jadi jauh lebih panjang dari klip lain.

⚠️ ATURAN DURASI:
- DURASI BEBAS — tidak ada batas minimum maupun maksimum.
- JANGAN pernah memotong klip hanya karena "sudah terlalu panjang". Yang menentukan akhir klip adalah SELESAINYA topik, bukan durasi.
- Klip bisa 15 detik, bisa 3 menit, bisa 5 menit — tidak masalah, selama topiknya tuntas dan memang layak viral.
- Lebih baik klip panjang yang utuh dan tuntas, daripada klip pendek yang terpotong di tengah pembahasan.

KRITERIA MOMEN (urut prioritas):
1. Hook kuat dalam 3 detik pertama
2. Puncak emosi: lucu, mengejutkan, mengharukan, tegang, kontroversial
3. Punchline/reveal — momen "aha" yang bikin ingin re-watch
4. Quote catchy yang gampang dikutip ulang
5. Reaksi natural yang kuat

ATURAN TITIK AWAL & AKHIR KLIP:
- Titik AWAL klip = mulai dari hook/momen kuat (bukan dari basa-basi pembuka).
- Titik AKHIR klip = setelah topik/cerita/poin yang dibicarakan benar-benar tuntas.
- Kalau pembahasan di satu topik berlanjut ke topik baru yang masih nyambung, BOLEH digabung.

HINDARI: bagian datar, basa-basi, transisi tanpa aksi, klip yang butuh konteks panjang, memotong di tengah kalimat, dan — yang paling penting — memotong sebelum topik yang dibahas benar-benar selesai.

KETENTUAN TEKNIS:
- Urutkan klip dari yang paling viral ke yang paling rendah
- Klip tidak boleh tumpang tindih
- Cek ulang tiap klip: apakah pembahasannya sudah benar-benar selesai di timestamp akhir?
- Cek ulang setiap timestamp agar sinkron dengan transkrip

FORMAT OUTPUT (WAJIB PERSIS, TANPA PENJELASAN TAMBAHAN):

Baris pertama tiap klip: mm:ss-mm:ss
Baris kedua: JUDUL: <judul singkat catchy max 60 karakter>
Baris ketiga: HOOK: <hook viral max 80 karakter>
Baris keempat: HASHTAG: <5 hashtag dipisah spasi>
Kosongkan satu baris antar klip.

CONTOH:

00:10-02:35
JUDUL: Reaksi Kaget Lihat Harga iPhone 15
HOOK: Ternyata harganya bikin dompet menjerit
HASHTAG: #iphone15 #review #techtok #gadgetindonesia #viral

05:20-09:10
JUDUL: Perbandingan iPhone 15 vs Samsung S24
HOOK: Siapa yang menang di uji coba ini?
HASHTAG: #samsung #iphone #comparison #techtok #shorts"""

def check_dependencies():
    """Cek ffmpeg/ffprobe/yt-dlp ada di PATH. Print peringatan jelas kalau tidak,
    supaya errornya tidak muncul samar-samar di tengah proses nanti."""
    missing = [b for b in ('ffmpeg', 'ffprobe', 'yt-dlp') if not shutil.which(b)]
    if missing:
        print('⚠️  Binary belum terpasang: ' + ', '.join(missing))
        print('    Jalankan ulang install.sh (OpenWrt), atau cek: opkg install ffmpeg && pip install yt-dlp')
    else:
        print('✓ Dependency oke: ffmpeg, ffprobe, yt-dlp ditemukan di PATH')
    return missing

def call_gemini_api(text_parts, timeout=180):
    """Kirim prompt ke Gemini, coba tiap model kandidat sampai ada yang berhasil.
    Mengembalikan (analysis_text, None) kalau sukses, atau (None, pesan_error)."""
    payload = {'contents': [{'parts': text_parts}],
               'generationConfig': {'temperature': 0.7, 'maxOutputTokens': 8192}}
    last_err = None
    for model in GEMINI_MODEL_CANDIDATES:
        url = f'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent'
        try:
            r = http_requests.post(url + '?key=' + GEMINI_API_KEY, json=payload, timeout=timeout)
        except http_requests.exceptions.Timeout:
            last_err = f'Gemini ({model}) timeout, coba lagi.'
            continue
        except Exception as e:
            last_err = f'Gemini ({model}) error koneksi: {e}'
            continue

        if r.status_code == 404:
            # Model ini sudah dimatikan/diganti nama oleh Google — coba kandidat berikutnya.
            last_err = f'Model {model} tidak tersedia (404), mencoba model lain...'
            print('[gemini] ' + last_err)
            continue
        if r.status_code != 200:
            last_err = f'Gemini ({model}) HTTP {r.status_code}: {r.text[:400]}'
            continue

        try:
            d = r.json()
        except Exception as e:
            last_err = f'Gemini ({model}) mengembalikan respons bukan JSON: {e}'
            continue

        candidates = d.get('candidates') or []
        if not candidates:
            reason = (d.get('promptFeedback') or {}).get('blockReason')
            if reason:
                last_err = f'Gemini ({model}) memblokir permintaan (alasan: {reason}). Coba video/SRT lain.'
            else:
                last_err = f'Gemini ({model}) tidak mengembalikan hasil analisis (respons kosong).'
            continue

        parts = (candidates[0].get('content') or {}).get('parts') or []
        text = ''.join(p.get('text', '') for p in parts).strip()
        if not text:
            last_err = f'Gemini ({model}) mengembalikan teks kosong.'
            continue

        return text, None

    return None, (last_err or 'Semua model Gemini gagal dihubungi.')

app = Flask(__name__)
jobs = {}
videos = {}
clips = {}
active_job_id = None

def job_is_running():
    """True kalau masih ada job unduh/potong yang aktif — dipakai supaya tidak ada
    2 proses ffmpeg/yt-dlp berat jalan bersamaan (bisa bikin HP nge-lag/crash)."""
    global active_job_id
    if not active_job_id:
        return False
    job = jobs.get(active_job_id)
    if not job:
        return False
    return job.get('status') in ('queued', 'downloading', 'cutting')

def save_state():
    try:
        with open(STATE_FILE, 'w', encoding='utf-8') as f:
            json.dump({'videos': videos, 'clips': clips}, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f'save_state error: {e}')

def load_state():
    global videos, clips
    if os.path.isfile(STATE_FILE):
        try:
            with open(STATE_FILE, 'r', encoding='utf-8') as f:
                s = json.load(f)
            videos = s.get('videos', {})
            clips  = s.get('clips', {})
        except Exception as e:
            print(f'load_state error: {e}')

    for fn in os.listdir(DOWNLOAD_DIR):
        p = os.path.join(DOWNLOAD_DIR, fn)
        if os.path.isfile(p) and fn not in videos:
            videos[fn] = {'path': p, 'title': os.path.splitext(fn)[0], 'srt_filename': None}
    for fn in list(videos.keys()):
        if not os.path.isfile(videos[fn].get('path', '')):
            del videos[fn]

    for fn in os.listdir(CLIP_DIR):
        p = os.path.join(CLIP_DIR, fn)
        if os.path.isfile(p) and fn.endswith('.mp4') and fn not in clips:
            clips[fn] = {'path': p, 'meta': {}}
    for fn in list(clips.keys()):
        if not os.path.isfile(clips[fn].get('path', '')):
            del clips[fn]

    for fn in os.listdir(CLIP_DIR):
        if fn.endswith('.ass'):
            mp4 = fn[:-4]
            if not os.path.isfile(os.path.join(CLIP_DIR, mp4)):
                try: os.remove(os.path.join(CLIP_DIR, fn))
                except: pass
    save_state()

def parse_ts(ts):
    parts = [float(p) for p in ts.strip().split(':')]
    if len(parts) == 3: return parts[0]*3600 + parts[1]*60 + parts[2]
    if len(parts) == 2: return parts[0]*60 + parts[1]
    return parts[0]

def probe_square(path, default=1080):
    try:
        r = subprocess.run(['ffprobe','-v','error','-select_streams','v:0',
                            '-show_entries','stream=width,height','-of','csv=p=0', path],
                           capture_output=True, text=True, timeout=20)
        w, h = r.stdout.strip().split(',')
        return min(int(w), int(h))
    except:
        return default

def has_audio(path):
    try:
        r = subprocess.run(['ffprobe','-v','error','-select_streams','a:0',
                            '-show_entries','stream=codec_type','-of','csv=p=0', path],
                           capture_output=True, text=True, check=True)
        return 'audio' in r.stdout.lower()
    except:
        return False

def bitrate_for(sq):
    kbps = int(8000 * (sq / 1080) ** 2)
    kbps = max(2500, min(kbps, 12000))
    return f'{kbps}k'

SRT_RE = re.compile(r'(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})')

def parse_srt(path):
    try:
        text = open(path, encoding='utf-8', errors='ignore').read()
    except:
        return []
    entries = []
    for block in re.split(r'\n\s*\n', text.strip()):
        lines = block.strip().splitlines()
        if len(lines) < 2: continue
        m, idx = None, 0
        for i, line in enumerate(lines):
            m = SRT_RE.search(line)
            if m: idx = i; break
        if not m: continue
        h1,m1,s1,ms1,h2,m2,s2,ms2 = map(int, m.groups())
        start = h1*3600 + m1*60 + s1 + ms1/1000
        end   = h2*3600 + m2*60 + s2 + ms2/1000
        txt = '\n'.join(l for l in lines[idx+1:] if l.strip())
        if txt: entries.append((start, end, txt))
    return entries

def _fmt_ass(t):
    t = max(0.0, t)
    h = int(t // 3600); t -= h*3600
    m = int(t // 60);   t -= m*60
    s = int(t); cs = int(round((t-s)*100))
    if cs >= 100: cs = 0; s += 1
    return f'{h:01d}:{m:02d}:{s:02d}.{cs:02d}'

def _esc_ass(t):
    return t.replace('\\','\\\\').replace('{','\\{').replace('}','\\}').replace('\n','\\N')

def build_ass(entries, cs, ce, out_path, sq):
    fontsize = max(22, round(sq * CONFIG['SUB_FONT_RATIO']))
    marginv  = round(sq * CONFIG['SUB_MARGIN_RATIO'])
    margin_lr= round(sq * CONFIG['SUB_MARGIN_LR_RATIO'])
    outline  = max(2, round(sq * CONFIG['SUB_OUTLINE_RATIO']))
    shadow   = CONFIG['SUB_SHADOW']
    font     = CONFIG['SUB_FONT']
    NL = chr(10)
    p = ['[Script Info]','ScriptType: v4.00+',
         'PlayResX: ' + str(sq),'PlayResY: ' + str(sq),
         'WrapStyle: 0','ScaledBorderAndShadow: yes','',
         '[V4+ Styles]',
         'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
         'Style: Default,' + font + ',' + str(fontsize) + ',&H00FFFFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,' + str(outline) + ',' + str(shadow) + ',2,' + str(margin_lr) + ',' + str(margin_lr) + ',' + str(marginv) + ',1','',
         '[Events]',
         'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text']
    count = 0
    for s, e, t in entries:
        if e <= cs or s >= ce: continue
        rs = max(s, cs) - cs
        re_= min(e, ce) - cs
        if re_ <= rs: continue
        count += 1
        p.append('Dialogue: 0,' + _fmt_ass(rs) + ',' + _fmt_ass(re_) + ',Default,,0,0,0,,' + _esc_ass(t))
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(NL.join(p) + NL)
    return count

FONTS_DIR = os.environ.get('AIVK_FONTS_DIR') or os.path.join(DATA_DIR, 'fonts')
FONTS_OPT = (":fontsdir='" + FONTS_DIR.replace(':', '\\:') + "'") if os.path.isdir(FONTS_DIR) else ''

def esc_ff(path):
    return path.replace('\\','\\\\').replace(':','\\:').replace("'","\\'")

def run_ffmpeg(cmd, duration, cb, timeout_sec=900):
    import time as _t
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, bufsize=1)
    err_lines = []
    def read_err():
        for line in proc.stderr:
            err_lines.append(line)
    th = threading.Thread(target=read_err, daemon=True); th.start()
    start_time = _t.time()
    for line in proc.stdout:
        line = line.strip()
        if _t.time() - start_time > timeout_sec:
            try: proc.kill()
            except: pass
            return False, 'TIMEOUT after ' + str(timeout_sec) + 's'
        if line.startswith('out_time_ms='):
            try:
                ms = int(line.split('=')[1])
                pct = int((ms/1_000_000)/duration*100)
                cb(max(0, min(99, pct)))
            except: pass
        elif line == 'progress=end':
            cb(100)
    proc.wait(); th.join(timeout=2)
    return proc.returncode == 0, ''.join(err_lines)[-3000:]

def detect_silences(video_path, start, duration, noise_db=-30, min_dur=0.6):
    # -vn: skip decode video (kita cuma butuh audio), jauh lebih cepat & tidak
    # gampang timeout di HP untuk klip yang panjang (durasi bebas sesuai prompt Gemini).
    cmd = ['ffmpeg','-hide_banner','-nostats','-ss',str(start),'-t',str(duration),'-i',video_path,
           '-vn','-af','silencedetect=noise='+str(noise_db)+'dB:d='+str(min_dur),'-f','null','-']
    timeout_sec = max(180, int(duration * 3) + 60)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
    except Exception as e:
        print('[silence] err ' + str(e)); return []
    starts = re.findall(r'silence_start: ([\d.]+)', r.stderr)
    ends   = re.findall(r'silence_end: ([\d.]+)', r.stderr)
    out = []
    for i, s in enumerate(starts):
        if i < len(ends): out.append((float(s), float(ends[i])))
    return out

def build_jump_ranges(silences, pad=0.2):
    out = []
    for s, e in silences:
        rs, re_ = s + pad, e - pad
        if re_ > rs + 0.1: out.append((rs, re_))
    return out

def build_select_expr(ranges):
    if not ranges: return None
    parts = ['between(t,'+str(s)+','+str(e)+')' for s, e in ranges]
    return 'not(' + '+'.join(parts) + ')'

def removed_time_before(t, ranges):
    total = 0.0
    for s, e in ranges:
        if t <= s: break
        if t >= e: total += e - s
        else:      total += t - s
    return total

def adjust_entries_for_jumpcut(entries, ranges):
    out = []
    for s, e, text in entries:
        ns = s - removed_time_before(s, ranges)
        ne = e - removed_time_before(e, ranges)
        if ne > ns + 0.05:
            out.append((ns, ne, text))
    return out

def do_cut(job_id, video_path, clips_data, vid, srt_path=None, music_path=None):
    jobs[job_id]['status'] = 'cutting'
    jobs[job_id]['message'] = 'Memotong klip...'
    jobs[job_id]['progress'] = 0
    jobs[job_id]['clip_status'] = []

    sq = probe_square(video_path)
    audio_ok = has_audio(video_path)

    sub_entries = None
    if srt_path and os.path.isfile(srt_path):
        sub_entries = parse_srt(srt_path)

    result = []
    total = len(clips_data)
    for i in range(total):
        jobs[job_id]['clip_status'].append({'index': i+1, 'status': 'pending', 'error': None})

    for i, clip in enumerate(clips_data):
        try:
            s, e = parse_ts(clip['start']), parse_ts(clip['end'])
            if e <= s:
                jobs[job_id]['clip_status'][i] = {'index': i+1, 'status':'error', 'error':'Timestamp invalid'}
                continue
            dur = e - s
            clip_fn   = 'clip_' + vid + '_' + str(i+1) + '.mp4'
            clip_path = os.path.join(CLIP_DIR, clip_fn)

            def cb(pct, idx=i, tot=total):
                overall = ((idx + pct/100.0)/tot) * 100
                jobs[job_id]['progress'] = max(0, min(100, int(overall)))
                jobs[job_id]['message']  = 'Klip ' + str(idx+1) + '/' + str(tot) + ' (' + str(pct) + '%)'

            jump_ranges, select_expr = [], None
            if AUTO_JUMPCUT:
                jobs[job_id]['message'] = 'Klip ' + str(i+1) + ': deteksi jeda...'
                sil = detect_silences(video_path, s, dur, JUMPCUT_NOISE_DB, JUMPCUT_MIN_SILENCE)
                jump_ranges = build_jump_ranges(sil, JUMPCUT_PAD)
                select_expr = build_select_expr(jump_ranges)
                print('[jumpcut] Klip ' + str(i+1) + ': ' + str(len(jump_ranges)) + ' jeda')

            ass_path = None
            if sub_entries:
                ce_list = []
                for ss, ee, tt in sub_entries:
                    if ee <= s or ss >= e: continue
                    rs, re_ = max(ss, s)-s, min(ee, e)-s
                    if re_ <= rs: continue
                    ce_list.append((rs, re_, tt))
                if ce_list:
                    if jump_ranges:
                        ce_list = adjust_entries_for_jumpcut(ce_list, jump_ranges)
                    if ce_list:
                        ass_path = os.path.join(CLIP_DIR, clip_fn + '.ass')
                        n = build_ass(ce_list, 0, dur, ass_path, sq)
                        if n == 0: ass_path = None

            vf_list = ["crop=w='min(iw,ih)':h='min(iw,ih)':x='(iw-min(iw,ih))/2':y='(ih-min(iw,ih))/2'"]
            if select_expr:
                vf_list.append("select='" + select_expr + "'")
                vf_list.append('setpts=N/FRAME_RATE/TB')
            if AUTO_EDIT:
                vf_list.append('eq=brightness=0.03:contrast=1.06:saturation=1.12')
                vf_list.append('fade=t=in:st=0:d=0.4')
                vf_list.append('fade=t=out:st=' + str(max(0.1, dur - 0.4)) + ':d=0.4')
            if ass_path:
                vf_list.append("subtitles='" + esc_ff(ass_path) + "'" + FONTS_OPT)
            vf = ','.join(vf_list)

            afilter = None
            if select_expr:
                afilter = "aselect='" + select_expr + "',asetpts=N/SR/TB"

            has_bgm = music_path and os.path.isfile(music_path)
            cmd = ['ffmpeg','-y','-ss',str(s),'-t',str(dur),'-i',video_path]
            if has_bgm:
                cmd += ['-stream_loop','-1','-i',music_path]

            enc_args = ['-c:v','libx264','-preset','veryfast',
                        '-profile:v', CONFIG['OUTPUT_PROFILE'],
                        '-level',     CONFIG['OUTPUT_LEVEL'],
                        '-b:v', bitrate_for(sq), '-pix_fmt','yuv420p']

            if has_bgm:
                vc = '[0:v]' + vf + '[vout]'
                bgm_vol = CONFIG['BGM_VOLUME']
                if audio_ok and afilter:
                    ac = f'[0:a]{afilter},volume=1.0[ao];[1:a]volume={bgm_vol}[ab];[ao][ab]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]'
                elif audio_ok:
                    ac = f'[0:a]volume=1.0[ao];[1:a]volume={bgm_vol}[ab];[ao][ab]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]'
                else:
                    ac = f'[1:a]volume={bgm_vol}[aout]'
                cmd += ['-filter_complex', vc + ';' + ac, '-map','[vout]', '-map','[aout]']
            else:
                cmd += ['-vf', vf, '-map','0:v:0', '-map','0:a:0?']
                if afilter: cmd += ['-af', afilter]

            cmd += enc_args
            cmd += ['-c:a','aac','-b:a', CONFIG['AUDIO_BITRATE'],
                    '-avoid_negative_ts','make_zero','-movflags','+faststart',
                    '-progress','pipe:1','-nostats', clip_path]

            # Klip bisa sangat panjang (durasi bebas sesuai topik) — timeout ikut
            # skala durasi klip supaya tidak dibunuh di tengah proses encode di HP.
            ffmpeg_timeout = max(CONFIG['FFMPEG_TIMEOUT'], int(dur * 8) + 180)
            ok, log = run_ffmpeg(cmd, dur, cb, timeout_sec=ffmpeg_timeout)
            if ok and os.path.isfile(clip_path) and os.path.getsize(clip_path) > 10000:
                result.append({'filename': clip_fn, 'meta': clip.get('meta', {})})
                clips[clip_fn] = {'path': clip_path, 'meta': clip.get('meta', {})}
                save_state()
                jobs[job_id]['clip_status'][i] = {'index': i+1, 'status':'done', 'error': None}
                print('[OK] Klip ' + str(i+1) + '/' + str(total))
            else:
                err = (log[:300] if log else 'Output invalid')
                jobs[job_id]['clip_status'][i] = {'index': i+1, 'status':'error', 'error': err}
                print('[ERR] Klip ' + str(i+1) + ': ' + err[:150])
                try:
                    if os.path.isfile(clip_path): os.remove(clip_path)
                except: pass

            if ass_path and os.path.isfile(ass_path):
                try: os.remove(ass_path)
                except: pass

        except Exception as ex:
            jobs[job_id]['clip_status'][i] = {'index': i+1, 'status':'error', 'error': str(ex)[:300]}
            print('[EXC] Klip ' + str(i+1) + ': ' + str(ex))

    jobs[job_id]['status']  = 'done'
    jobs[job_id]['message'] = 'Selesai!'
    jobs[job_id]['progress']= 100
    jobs[job_id]['clips']   = result

YT_SRT_CACHE = {}

def extract_video_id(url):
    patterns = [
        r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([A-Za-z0-9_-]{11})',
        r'youtube\.com/shorts/([A-Za-z0-9_-]{11})',
    ]
    for p in patterns:
        m = re.search(p, url)
        if m: return m.group(1)
    return None

def fetch_youtube_vtt(url, video_id):
    out_tpl = os.path.join(SRT_DIR, video_id)
    for lang in CONFIG['YT_LANG_PRIORITY']:
        cmd = ['yt-dlp','--write-auto-subs','--sub-langs',lang,
               '--skip-download','--no-part','-o',out_tpl,url]
        try:
            subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            vtt_path = out_tpl + '.' + lang + '.vtt'
            if os.path.isfile(vtt_path) and os.path.getsize(vtt_path) > 100:
                print('[yt-srt] VTT downloaded: ' + vtt_path)
                return vtt_path, lang
        except Exception as e:
            print('[yt-srt] Error ' + lang + ': ' + str(e))
    return None, None

def clean_srt_file(srt_path):
    try:
        with open(srt_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print('[clean-srt] Error baca: ' + str(e)); return 0

    TS_RE = re.compile(r'(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})')
    def ts_sec(t):
        h, m, rest = t.split(':'); s, ms = rest.split(',')
        return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000
    def fmt_ts(sec):
        sec = max(0, sec)
        h = int(sec // 3600); sec -= h*3600
        m = int(sec // 60); sec -= m*60
        s = int(sec); ms = int(round((sec - s) * 1000))
        if ms >= 1000: ms = 0; s += 1
        if s >= 60: s = 0; m += 1
        return str(h).zfill(2)+':'+str(m).zfill(2)+':'+str(s).zfill(2)+','+str(ms).zfill(3)

    raw = []
    for block in re.split(r'\n\s*\n', content.strip()):
        lines = block.strip().split('\n')
        if len(lines) < 2: continue
        ts_idx = -1
        for i, ln in enumerate(lines):
            if TS_RE.search(ln): ts_idx = i; break
        if ts_idx < 0: continue
        m = TS_RE.search(lines[ts_idx])
        text = ' '.join(l.strip() for l in lines[ts_idx+1:] if l.strip())
        if not text: continue
        raw.append((ts_sec(m.group(1)), ts_sec(m.group(2)), text))
    if not raw:
        print('[clean-srt] Tidak ada entry valid'); return 0

    final, prev_text = [], ''
    for s, e, text in raw:
        text = text.strip()
        if not text: continue
        if text == prev_text:
            if final: final[-1] = (final[-1][0], e, final[-1][2])
            continue
        if prev_text and text.startswith(prev_text):
            delta = text[len(prev_text):].strip()
            if delta: final.append((s, e, delta))
            prev_text = text; continue
        prev_words, curr_words = prev_text.split(), text.split()
        overlap = 0
        for k in range(min(len(prev_words), len(curr_words)), 0, -1):
            if prev_words[-k:] == curr_words[:k]: overlap = k; break
        if overlap > 0:
            delta_words = curr_words[overlap:]
            if delta_words: final.append((s, e, ' '.join(delta_words)))
            prev_text = text; continue
        if text in prev_text:
            prev_text = text; continue
        final.append((s, e, text)); prev_text = text

    if not final:
        print('[clean-srt] Delta kosong, fallback ke raw'); final = raw

    out = []
    for i, (s, e, t) in enumerate(final, 1):
        out += [str(i), fmt_ts(s) + ' --> ' + fmt_ts(e), t, '']
    try:
        with open(srt_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(out))
    except Exception as e:
        print('[clean-srt] Error tulis: ' + str(e)); return 0
    print('[clean-srt] ' + str(len(raw)) + ' raw -> ' + str(len(final)) + ' delta')
    return len(final)

def convert_vtt_to_srt(vtt_path, srt_path):
    cmd = ['ffmpeg','-y','-i',vtt_path,srt_path]
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=True)
        if not os.path.isfile(srt_path): return False
        clean_srt_file(srt_path)
        return True
    except Exception as e:
        print('[yt-srt] Convert error: ' + str(e)); return False

def process_existing_job(job_id, video_filename, clips_data, ratio='asli', srt_path=None, music_path=None):
    info = videos.get(video_filename)
    if not info or not os.path.exists(info['path']):
        jobs[job_id] = {'status':'error','message':'File tidak ditemukan.',
                        'progress':0,'clips':[],'error':'File tidak ditemukan.'}
        return

    srt_fn = info.get('srt_filename')
    srt_ok = srt_fn and os.path.isfile(os.path.join(SRT_DIR, srt_fn))

    if not srt_ok and not srt_path:
        source_url = info.get('source_url')
        if source_url:
            vid = extract_video_id(source_url)
            if vid:
                candidate = os.path.join(SRT_DIR, vid + '.srt')
                if os.path.isfile(candidate):
                    srt_path = candidate
                    info['srt_filename'] = vid + '.srt'; save_state()
                else:
                    vtt_path, lang = fetch_youtube_vtt(source_url, vid)
                    if vtt_path:
                        candidate_srt = os.path.join(SRT_DIR, vid + '.srt')
                        if convert_vtt_to_srt(vtt_path, candidate_srt):
                            srt_path = candidate_srt
                            info['srt_filename'] = vid + '.srt'; save_state()
    elif not srt_path and srt_fn:
        candidate = os.path.join(SRT_DIR, srt_fn)
        if os.path.isfile(candidate): srt_path = candidate

    if srt_path and not os.path.isfile(srt_path): srt_path = None

    jobs[job_id] = {'status':'queued','message':'Menunggu...','progress':0,
                    'clips':[],'error':None,'clip_status':[]}
    do_cut(job_id, info['path'], clips_data,
           os.path.splitext(video_filename)[0], srt_path, music_path)

def download_and_cut(job_id, url, clips_data, srt_path=None, music_path=None, all_clips=None):
    jobs[job_id] = {'status':'downloading','message':'Mengunduh video...',
                    'progress':0,'clips':[],'error':None}

    vid = uuid.uuid4().hex[:8]
    video_path = os.path.join(DOWNLOAD_DIR, f'{vid}.mp4')
    try:
        proc = subprocess.Popen([
            'yt-dlp','-f', CONFIG['YT_DOWNLOAD_FORMAT'],
            '--merge-output-format','mp4','--no-playlist',
            '-N', CONFIG['YT_DOWNLOAD_THREADS'],'--newline','-o',video_path,url
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

        for line in iter(proc.stdout.readline, ''):
            m = re.search(r'\[download\]\s+(\d+(?:\.\d+)?)%', line.strip())
            if m:
                p = float(m.group(1))
                jobs[job_id]['progress'] = int(p)
                jobs[job_id]['message']  = f'Mengunduh video... {int(p)}%'
        proc.wait()
        if proc.returncode != 0:
            jobs[job_id]['status'] = 'error'
            jobs[job_id]['error']  = 'Gagal unduh video.'
            return
    except Exception as ex:
        jobs[job_id]['status'] = 'error'
        jobs[job_id]['error']  = f'Error unduh: {ex}'
        return

    vfn = f'{vid}.mp4'
    videos[vfn] = {
        'path': video_path,
        'title': f'Video {vid}',
        'srt_filename': os.path.basename(srt_path) if srt_path else None,
        'last_clips': all_clips if all_clips else clips_data,
        'last_ratio': '1:1',
        'source_url': url,
    }
    save_state()
    do_cut(job_id, video_path, clips_data, vid, srt_path, music_path)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/upload_srt', methods=['POST'])
def upload_srt():
    if 'file' not in request.files: return jsonify({'error':'Tidak ada file'}), 400
    f = request.files['file']
    if not f.filename or not f.filename.lower().endswith('.srt'):
        return jsonify({'error':'Hanya .srt'}), 400
    fn = f'{uuid.uuid4().hex[:10]}.srt'
    f.save(os.path.join(SRT_DIR, fn))
    return jsonify({'filename': fn})

@app.route('/upload_music', methods=['POST'])
def upload_music():
    if 'file' not in request.files: return jsonify({'error':'Tidak ada file'}), 400
    f = request.files['file']
    if not f.filename: return jsonify({'error':'Nama kosong'}), 400
    ext = os.path.splitext(f.filename)[1].lower()
    if ext not in ('.mp3','.wav','.m4a','.aac','.ogg','.flac'):
        return jsonify({'error':'Format tidak didukung'}), 400
    fn = f'{uuid.uuid4().hex[:12]}{ext}'
    f.save(os.path.join(MUSIC_DIR, fn))
    return jsonify({'filename': fn})

@app.route('/analyze_youtube', methods=['POST'])
def analyze_youtube():
    data = request.get_json()
    if not data: return jsonify({'error':'Invalid JSON'}), 400
    url = data.get('url', '').strip()
    if not url: return jsonify({'error':'URL kosong'}), 400
    if not GEMINI_API_KEY or GEMINI_API_KEY.startswith('ISI_'):
        return jsonify({'error':'GEMINI_API_KEY belum diisi. Isi lewat file .env atau CONFIG di app.py'}), 500

    vid = extract_video_id(url)
    if not vid: return jsonify({'error':'URL YouTube tidak valid'}), 400

    cache = YT_SRT_CACHE.get(vid)
    if cache and os.path.isfile(cache['vtt']):
        vtt_path, srt_path = cache['vtt'], cache['srt']
    else:
        vtt_path, lang = fetch_youtube_vtt(url, vid)
        if not vtt_path:
            return jsonify({'error':'Video ini tidak punya subtitle otomatis. Upload SRT manual atau pilih video lain.'}), 404
        srt_path = os.path.join(SRT_DIR, vid + '.srt')
        convert_vtt_to_srt(vtt_path, srt_path)
        YT_SRT_CACHE[vid] = {'vtt': vtt_path, 'srt': srt_path, 'created': __import__('time').time()}

    try:
        with open(vtt_path, 'r', encoding='utf-8', errors='ignore') as f:
            vtt_content = f.read()
    except Exception as e:
        return jsonify({'error':'Gagal baca VTT: ' + str(e)}), 500
    if len(vtt_content) > CONFIG['YT_MAX_VTT_CHARS']:
        vtt_content = vtt_content[:CONFIG['YT_MAX_VTT_CHARS']]

    analysis, err = call_gemini_api([{'text': GEMINI_PROMPT}, {'text': vtt_content}])
    if err:
        return jsonify({'error': err}), 500

    return jsonify({'vtt_filename': os.path.basename(vtt_path),
                    'srt_filename': os.path.basename(srt_path),
                    'video_id': vid, 'analysis': analysis})

@app.route('/analyze_srt', methods=['POST'])
def analyze_srt():
    if not GEMINI_API_KEY or GEMINI_API_KEY.startswith('ISI_'):
        return jsonify({'error':'GEMINI_API_KEY belum diisi. Isi lewat file .env atau CONFIG di app.py'}), 500

    srt_fn, srt_path = None, None
    if 'file' in request.files and request.files['file'].filename:
        f = request.files['file']
        if not f.filename.lower().endswith('.srt'):
            return jsonify({'error':'Hanya .srt'}), 400
        srt_fn = f'{uuid.uuid4().hex[:10]}.srt'
        srt_path = os.path.join(SRT_DIR, srt_fn)
        f.save(srt_path)
    elif request.form.get('srt_filename'):
        srt_fn = request.form.get('srt_filename')
        srt_path = os.path.join(SRT_DIR, srt_fn)
        if not os.path.isfile(srt_path): return jsonify({'error':'SRT tidak ditemukan'}), 404
    else:
        return jsonify({'error':'Tidak ada SRT'}), 400

    try:
        with open(srt_path, 'r', encoding='utf-8', errors='ignore') as f:
            srt_content = f.read()
    except Exception as ex:
        return jsonify({'error': f'Baca SRT gagal: {ex}'}), 500
    if len(srt_content) > 500000: srt_content = srt_content[:500000]

    analysis, err = call_gemini_api([{'text': GEMINI_PROMPT}, {'text': srt_content}])
    if err:
        return jsonify({'error': err}), 500

    return jsonify({'srt_filename': srt_fn, 'analysis': analysis})

@app.route('/video_history/<filename>')
def video_history(filename):
    info = videos.get(filename)
    if not info: return jsonify({'error':'Video tidak ditemukan'}), 404
    return jsonify({
        'filename': filename,
        'title': info.get('title', filename),
        'has_srt': bool(info.get('srt_filename') and os.path.isfile(os.path.join(SRT_DIR, info.get('srt_filename', '')))),
        'srt_filename': info.get('srt_filename'),
        'last_clips': info.get('last_clips', []),
    })

@app.route('/process_existing', methods=['POST'])
def process_existing():
    data = request.get_json()
    if not data: return jsonify({'error':'Invalid JSON'}), 400
    video_fn   = data.get('video_filename')
    clips_data = data.get('clips')
    all_clips  = data.get('all_clips')
    srt_fn     = data.get('srt_filename')
    music_fn   = data.get('music_filename')

    if not video_fn:   return jsonify({'error':'video_filename wajib'}), 400
    if not clips_data: return jsonify({'error':'Klip kosong'}), 400
    if job_is_running():
        return jsonify({'error':'Masih ada proses lain (unduh/potong klip) yang berjalan. Tunggu sampai selesai dulu.'}), 409
    info = videos.get(video_fn)
    if not info or not os.path.isfile(info['path']):
        return jsonify({'error':'Video tidak ditemukan'}), 404

    info['last_clips'] = all_clips if all_clips else clips_data
    save_state()

    srt_path = os.path.join(SRT_DIR, srt_fn) if srt_fn else None
    if srt_path and not os.path.isfile(srt_path): srt_path = None
    music_path = os.path.join(MUSIC_DIR, music_fn) if music_fn else None
    if music_path and not os.path.isfile(music_path): music_path = None

    job_id = uuid.uuid4().hex
    jobs[job_id] = {'status':'queued','message':'Menunggu...','progress':0,
                    'clips':[],'error':None,'created':__import__('time').time(),'clip_status':[]}
    global active_job_id
    active_job_id = job_id

    t = threading.Thread(target=process_existing_job,
                         args=(job_id, video_fn, clips_data, '1:1', srt_path, music_path))
    t.daemon = True; t.start()
    return jsonify({'job_id': job_id})

@app.route('/process', methods=['POST'])
def process():
    data = request.get_json()
    if not data: return jsonify({'error':'Invalid JSON'}), 400
    url        = data.get('url')
    clips_data = data.get('clips')
    all_clips  = data.get('all_clips')
    srt_fn     = data.get('srt_filename')
    music_fn   = data.get('music_filename')

    if not url:        return jsonify({'error':'URL wajib diisi'}), 400
    if not clips_data: return jsonify({'error':'Klip kosong'}), 400
    if job_is_running():
        return jsonify({'error':'Masih ada proses lain (unduh/potong klip) yang berjalan. Tunggu sampai selesai dulu.'}), 409

    srt_path = os.path.join(SRT_DIR, srt_fn) if srt_fn else None
    if srt_path and not os.path.isfile(srt_path):
        return jsonify({'error':'SRT tidak ditemukan'}), 404
    music_path = os.path.join(MUSIC_DIR, music_fn) if music_fn else None
    if music_path and not os.path.isfile(music_path):
        return jsonify({'error':'Musik tidak ditemukan'}), 404

    global active_job_id
    job_id = uuid.uuid4().hex
    jobs[job_id] = {'status':'queued','message':'Menunggu...','progress':0,
                    'clips':[],'error':None,'url':url,'created':__import__('time').time()}
    active_job_id = job_id
    t = threading.Thread(target=download_and_cut,
                         args=(job_id, url, clips_data, srt_path, music_path, all_clips))
    t.daemon = True; t.start()
    return jsonify({'job_id': job_id})

@app.route('/active_job')
def get_active_job():
    global active_job_id
    if not active_job_id or active_job_id not in jobs:
        return jsonify({'active': False})
    job = jobs[active_job_id]
    return jsonify({'active': True, 'job_id': active_job_id,
                    'status': job.get('status'), 'message': job.get('message'),
                    'progress': job.get('progress', 0), 'error': job.get('error'),
                    'clips_count': len(job.get('clips', []))})

@app.route('/active_job/clear', methods=['POST'])
def clear_active_job():
    global active_job_id
    active_job_id = None
    return jsonify({'success': True})

@app.route('/status/<job_id>')
def status(job_id):
    job = jobs.get(job_id)
    if not job: return jsonify({'error':'Job tidak ditemukan'}), 404
    out = []
    for c in job.get('clips', []):
        fn = c['filename']
        out.append({'filename': fn, 'meta': c.get('meta', {}),
                    'download_url': url_for('download_clip', filename=fn, _external=True),
                    'stream_url':   url_for('stream_clip',   filename=fn, _external=True)})
    return jsonify({'status': job.get('status'), 'message': job.get('message'),
                    'progress': job.get('progress'), 'clips': out, 'error': job.get('error')})

@app.route('/files')
def list_files():
    vids = []
    for fn, info in videos.items():
        if os.path.exists(info['path']):
            srt_fn = info.get('srt_filename')
            has_srt = bool(srt_fn and os.path.isfile(os.path.join(SRT_DIR, srt_fn)))
            vids.append({'filename': fn, 'title': info.get('title', fn),
                         'stream_url':   url_for('stream_video',   filename=fn, _external=True),
                         'download_url': url_for('download_video', filename=fn, _external=True),
                         'has_srt': has_srt})
    cl = []
    for fn, info in clips.items():
        if os.path.exists(info['path']):
            cl.append({'filename': fn, 'meta': info.get('meta', {}),
                       'stream_url':   url_for('stream_clip',   filename=fn, _external=True),
                       'download_url': url_for('download_clip', filename=fn, _external=True)})
    return jsonify({'videos': vids, 'clips': cl})

@app.route('/delete/clips_batch', methods=['POST'])
def delete_clips_batch():
    data = request.get_json() or {}
    deleted, errors = 0, []
    if data.get('all'):
        for fn in list(clips.keys()):
            info = clips[fn]
            try:
                if os.path.isfile(info['path']): os.remove(info['path'])
                del clips[fn]; deleted += 1
            except Exception as e: errors.append(f'{fn}: {e}')
    else:
        for fn in data.get('filenames', []):
            info = clips.pop(fn, None)
            if not info: continue
            try:
                if os.path.isfile(info['path']): os.remove(info['path'])
                deleted += 1
            except Exception as e: errors.append(f'{fn}: {e}')
    save_state()
    return jsonify({'success': True, 'deleted': deleted, 'errors': errors})

@app.route('/delete/video/<filename>', methods=['DELETE'])
def delete_video(filename):
    info = videos.pop(filename, None)
    if info:
        try: os.remove(info['path'])
        except: pass
        srt_fn = info.get('srt_filename')
        if srt_fn:
            still = any(v.get('srt_filename') == srt_fn for v in videos.values())
            if not still:
                try: os.remove(os.path.join(SRT_DIR, srt_fn))
                except: pass
        save_state()
        return jsonify({'success': True})
    return jsonify({'error':'Tidak ditemukan'}), 404

@app.route('/delete/clip/<filename>', methods=['DELETE'])
def delete_clip(filename):
    info = clips.pop(filename, None)
    if info:
        try: os.remove(info['path'])
        except: pass
        save_state()
        return jsonify({'success': True})
    return jsonify({'error':'Tidak ditemukan'}), 404

@app.route('/download/<filename>')
def download_clip(filename):
    return send_from_directory(CLIP_DIR, filename, as_attachment=True)

@app.route('/stream/<filename>')
def stream_clip(filename):
    return send_file(os.path.join(CLIP_DIR, filename), mimetype='video/mp4', conditional=True)

@app.route('/download_video/<filename>')
def download_video(filename):
    return send_from_directory(DOWNLOAD_DIR, filename, as_attachment=True)

@app.route('/stream_video/<filename>')
def stream_video(filename):
    return send_file(os.path.join(DOWNLOAD_DIR, filename), mimetype='video/mp4', conditional=True)

if __name__ == '__main__':
    load_state()
    check_dependencies()
    PORT = int(os.environ.get('AIVK_PORT') or 5000)
    print('🎬 AI Video Klip V4 (OpenWrt) — http://0.0.0.0:' + str(PORT))
    print('📁 Data: ' + DATA_DIR)
    if not GEMINI_API_KEY or GEMINI_API_KEY.startswith('ISI_'):
        print('⚠️  WARNING: GEMINI_API_KEY belum diisi. Isi lewat file .env (GEMINI_API_KEY=...) atau CONFIG di app.py!')
    app.run(host='0.0.0.0', port=PORT, debug=False, threaded=True)
AIVK_EOF_APP

STEP="menulis templates/index.html"
cat > "$INSTALL_DIR/templates/index.html" <<'AIVK_EOF_HTML'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AI Video Klip V4</title>
<style>
:root{
  --bg:#06131a;--bg-2:#081b24;--card:#0d2430;--card-hover:#12313f;
  --border:#1a3b4a;--border-hi:#2a5c70;--text:#e0f4f8;--text-muted:#7fa8b8;
  --primary:#0d9488;--primary-2:#14b8a6;--accent:#22d3ee;--pink:#fb7185;
  --cyan:#06b6d4;--success:#10b981;--danger:#ef4444;
  --radius:16px;--shadow:0 12px 40px rgba(0,0,0,0.55);--glow:0 0 40px rgba(20,184,166,0.22);
}
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:'Inter','Segoe UI',Tahoma,sans-serif;
  background:radial-gradient(ellipse at 20% 0%,#0c3b3a 0%,transparent 55%),
    radial-gradient(ellipse at 80% 100%,#082836 0%,transparent 55%),
    linear-gradient(180deg,#06131a 0%,#041016 100%);
  background-attachment:fixed;color:var(--text);min-height:100vh;
  display:flex;justify-content:center;align-items:flex-start;padding:2rem 1rem;}
.container{max-width:940px;width:100%;
  background:linear-gradient(135deg,rgba(13,36,48,0.92),rgba(8,27,36,0.96));
  border-radius:var(--radius);box-shadow:var(--shadow),var(--glow);
  padding:2rem;border:1px solid var(--border);backdrop-filter:blur(20px);}
.header{display:flex;align-items:center;gap:1rem;margin-bottom:0.5rem;}
.logo{width:48px;height:48px;border-radius:12px;
  background:linear-gradient(135deg,var(--primary-2),var(--accent));
  display:flex;align-items:center;justify-content:center;font-size:1.6rem;
  box-shadow:0 4px 20px rgba(20,184,166,0.45);}
h1{font-size:1.7rem;font-weight:700;background:linear-gradient(135deg,#fff,#5eead4);
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;letter-spacing:-0.5px;}
.subtitle{color:var(--text-muted);font-size:0.88rem;margin-bottom:1.5rem;margin-left:64px;}
.tab-nav{display:flex;gap:0.4rem;margin-bottom:1.5rem;background:rgba(6,19,26,0.7);
  padding:0.4rem;border-radius:10px;border:1px solid var(--border);}
.tab-button{flex:1;background:transparent;border:none;color:var(--text-muted);
  padding:0.7rem;border-radius:8px;cursor:pointer;font-weight:600;font-size:0.9rem;
  transition:all 0.2s;font-family:inherit;}
.tab-button:hover{background:rgba(20,184,166,0.1);color:var(--text);}
.tab-button.active{background:linear-gradient(135deg,var(--primary),var(--primary-2));
  color:#fff;box-shadow:0 4px 12px rgba(20,184,166,0.35);}
.tab-content{display:none;}
.tab-content.active{display:block;animation:fadeIn 0.3s;}
@keyframes fadeIn{from{opacity:0;transform:translateY(4px);}to{opacity:1;transform:translateY(0);}}
label{display:flex;align-items:center;gap:0.5rem;margin-bottom:0.5rem;margin-top:1rem;
  font-weight:600;color:var(--text);font-size:0.9rem;}
.step-num{width:24px;height:24px;border-radius:50%;
  background:linear-gradient(135deg,var(--primary-2),var(--accent));
  display:inline-flex;align-items:center;justify-content:center;
  font-size:0.75rem;font-weight:700;color:#04212a;flex-shrink:0;}
input[type="text"],textarea,select{width:100%;padding:0.75rem 0.9rem;
  background:rgba(6,19,26,0.75);border:1px solid var(--border);border-radius:8px;
  color:var(--text);font-size:0.9rem;font-family:inherit;transition:all 0.2s;}
input[type="text"]:focus,textarea:focus,select:focus{outline:none;
  border-color:var(--accent);box-shadow:0 0 0 3px rgba(34,211,238,0.18);
  background:rgba(8,27,36,0.9);}
textarea{resize:vertical;font-family:inherit;line-height:1.5;}
select{cursor:pointer;}
input[type="file"]{width:100%;padding:0.7rem;background:rgba(6,19,26,0.55);
  border:1.5px dashed var(--border-hi);border-radius:8px;color:var(--text-muted);
  font-size:0.85rem;cursor:pointer;font-family:inherit;transition:all 0.2s;}
input[type="file"]:hover{border-color:var(--accent);background:rgba(34,211,238,0.06);}
input[type="file"]::file-selector-button{
  background:linear-gradient(135deg,var(--primary),var(--primary-2));
  color:#fff;border:none;padding:0.45rem 0.9rem;border-radius:6px;
  cursor:pointer;margin-right:0.7rem;font-weight:600;font-family:inherit;font-size:0.85rem;}
button{background:linear-gradient(135deg,var(--primary),var(--primary-2));
  color:white;border:none;padding:0.75rem 1.5rem;border-radius:8px;
  cursor:pointer;font-weight:600;font-size:0.9rem;font-family:inherit;
  transition:all 0.2s;box-shadow:0 4px 15px rgba(20,184,166,0.3);}
button:hover:not(:disabled){transform:translateY(-1px);
  box-shadow:0 6px 20px rgba(20,184,166,0.5);}
button:active:not(:disabled){transform:translateY(0);}
button:disabled{opacity:0.5;cursor:not-allowed;box-shadow:none;}
.btn-success{background:linear-gradient(135deg,#059669,var(--success));
  box-shadow:0 4px 15px rgba(16,185,129,0.35);}
.btn-success:hover:not(:disabled){box-shadow:0 6px 20px rgba(16,185,129,0.55);}
.btn-danger{background:linear-gradient(135deg,#dc2626,var(--danger));
  box-shadow:0 4px 15px rgba(239,68,68,0.3);}
.btn-danger:hover:not(:disabled){box-shadow:0 6px 20px rgba(239,68,68,0.5);}
.btn-ghost{background:transparent;color:var(--text-muted);
  border:1px solid var(--border-hi);box-shadow:none;}
.btn-ghost:hover:not(:disabled){background:rgba(20,184,166,0.1);color:var(--text);
  box-shadow:none;transform:none;}
.btn-blue{background:linear-gradient(135deg,#0891b2,var(--cyan));
  box-shadow:0 4px 15px rgba(6,182,212,0.35);}
.btn-blue:hover:not(:disabled){box-shadow:0 6px 20px rgba(6,182,212,0.55);}
.btn-sm{padding:0.4rem 0.8rem;font-size:0.82rem;}
.button-group{display:flex;gap:0.6rem;flex-wrap:wrap;margin:1.2rem 0;}
.status-msg{font-size:0.85rem;padding:0.5rem 0.75rem;border-radius:6px;
  color:var(--text-muted);font-style:italic;min-height:1.5em;margin-top:0.4rem;transition:all 0.2s;}
.status-msg.ok{color:var(--success);font-style:normal;background:rgba(16,185,129,0.08);}
.status-msg.err{color:#fca5a5;font-style:normal;background:rgba(239,68,68,0.08);}
.divider{border:none;height:1px;
  background:linear-gradient(90deg,transparent,var(--border),transparent);margin:1.5rem 0;}
.progress-wrap{width:100%;background:rgba(6,19,26,0.85);border-radius:20px;
  margin:0.6rem 0 1rem;overflow:hidden;height:22px;border:1px solid var(--border);}
.progress-bar{height:100%;width:0%;
  background:linear-gradient(90deg,var(--primary-2),var(--accent),var(--pink));
  border-radius:20px;transition:width 0.4s ease;box-shadow:0 0 15px rgba(34,211,238,0.5);}
.progress-text{text-align:center;margin-bottom:0.4rem;font-weight:600;
  font-size:0.88rem;color:var(--text);}
.analysis-box{display:flex;align-items:center;gap:0.7rem;padding:0.75rem 1rem;
  background:linear-gradient(135deg,rgba(20,184,166,0.15),rgba(34,211,238,0.1));
  border:1px solid var(--border-hi);border-radius:8px;margin:0.8rem 0;font-size:0.86rem;}
.spinner{display:inline-block;width:16px;height:16px;
  border:2px solid rgba(20,184,166,0.3);border-top-color:var(--accent);
  border-radius:50%;animation:spin 0.8s linear infinite;flex-shrink:0;}
@keyframes spin{to{transform:rotate(360deg);}}
.analysis-box.ok{border-color:var(--success);background:rgba(16,185,129,0.08);}
.analysis-box.ok .spinner{display:none;}
.analysis-box.err{border-color:var(--danger);background:rgba(239,68,68,0.08);}
.analysis-box.err .spinner{display:none;}
.analysis-elapsed{margin-left:auto;color:var(--text-muted);
  font-family:'JetBrains Mono','Courier New',monospace;font-size:0.8rem;}
.clip-block{background:linear-gradient(135deg,rgba(13,36,48,0.9),rgba(8,27,36,0.7));
  border:1px solid var(--border);border-radius:10px;padding:1rem;
  margin-bottom:0.9rem;transition:all 0.2s;}
.clip-block:hover{border-color:var(--border-hi);transform:translateX(2px);}
.clip-block-header{font-weight:700;font-size:0.95rem;color:var(--text);
  margin-bottom:0.6rem;display:flex;align-items:center;gap:0.5rem;}
.clip-block-header::before{content:'🎬';font-size:1rem;}
.clip-meta{background:rgba(6,19,26,0.75);border-left:3px solid var(--pink);
  padding:0.6rem 0.8rem;border-radius:6px;margin-bottom:0.5rem;font-size:0.84rem;}
.meta-row{display:flex;align-items:flex-start;gap:0.6rem;padding:0.3rem 0;line-height:1.4;}
.meta-label{font-weight:600;color:var(--pink);min-width:75px;font-size:0.78rem;flex-shrink:0;}
.meta-value{flex:1;word-break:break-word;color:var(--text);}
.meta-copy-btn{background:rgba(20,184,166,0.18);border:none;color:var(--text);
  cursor:pointer;padding:0.2rem 0.5rem;border-radius:4px;font-size:0.8rem;
  transition:all 0.2s;box-shadow:none;}
.meta-copy-btn:hover{background:var(--primary-2);color:#04212a;box-shadow:none;transform:none;}
.empty-note{color:var(--text-muted);font-size:0.85rem;font-style:italic;
  padding:0.8rem 0;text-align:center;}
.file-card{background:linear-gradient(135deg,rgba(13,36,48,0.9),rgba(8,27,36,0.7));
  border:1px solid var(--border);border-radius:10px;padding:1rem;
  margin-bottom:1rem;transition:all 0.2s;}
.file-card:hover{border-color:var(--border-hi);box-shadow:0 8px 30px rgba(0,0,0,0.35);}
.file-card video{width:100%;max-height:500px;border-radius:8px;background:#000;display:block;}
.file-card-info{margin-top:0.8rem;}
.file-card-info .filename{font-weight:600;font-size:0.9rem;color:var(--text);
  margin-bottom:0.4rem;display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap;}
.file-card-info .filename small{color:var(--text-muted);font-weight:400;
  font-size:0.78rem;font-family:monospace;}
.badge-srt{display:inline-block;background:rgba(6,182,212,0.15);color:var(--cyan);
  padding:0.15rem 0.5rem;border-radius:4px;font-size:0.72rem;font-weight:600;}
.clip-meta-display{margin-top:0.7rem;padding:0.7rem 0.9rem;
  background:rgba(6,19,26,0.75);border-left:3px solid var(--pink);
  border-radius:6px;font-size:0.83rem;}
.clip-meta-display .meta-row{display:flex;gap:0.6rem;padding:0.3rem 0;
  align-items:flex-start;line-height:1.4;}
.clip-meta-display .meta-label{font-weight:600;color:var(--pink);
  min-width:75px;font-size:0.78rem;flex-shrink:0;}
.clip-meta-display .meta-value{flex:1;word-break:break-word;
  user-select:all;color:var(--text);}
.file-actions{display:flex;gap:0.5rem;flex-wrap:wrap;margin-top:0.8rem;}
.file-actions a{text-decoration:none;color:var(--accent);font-weight:600;
  padding:0.4rem 0.85rem;border:1px solid var(--accent);border-radius:6px;
  font-size:0.82rem;transition:all 0.2s;}
.file-actions a:hover{background:var(--accent);color:#04212a;
  box-shadow:0 4px 12px rgba(34,211,238,0.45);}
.section-title{display:flex;align-items:center;gap:0.5rem;color:var(--text);
  margin:1.5rem 0 0.8rem;font-size:1.05rem;font-weight:700;}
.section-title::before{content:'';width:4px;height:20px;
  background:linear-gradient(180deg,var(--primary-2),var(--accent));border-radius:2px;}
.success-banner{background:linear-gradient(135deg,rgba(16,185,129,0.15),rgba(34,211,238,0.1));
  border:1px solid var(--success);border-radius:10px;padding:1rem 1.2rem;margin-bottom:1rem;}
.success-banner h3{color:var(--success);margin-bottom:0.3rem;font-size:1.05rem;font-weight:700;}
.success-banner p{color:var(--text-muted);font-size:0.85rem;line-height:1.4;}
.toast{position:fixed;bottom:30px;left:50%;transform:translateX(-50%) translateY(100px);
  background:linear-gradient(135deg,var(--primary-2),#059669);color:#04212a;
  padding:0.85rem 1.5rem;border-radius:10px;font-weight:700;
  box-shadow:0 8px 30px rgba(20,184,166,0.45);z-index:9999;opacity:0;
  transition:all 0.3s cubic-bezier(0.34,1.56,0.64,1);}
.toast.show{transform:translateX(-50%) translateY(0);opacity:1;}
.toast.err{background:linear-gradient(135deg,var(--danger),#dc2626);color:#fff;
  box-shadow:0 8px 30px rgba(239,68,68,0.45);}
@media(max-width:600px){body{padding:1rem 0.5rem;}.container{padding:1.2rem;}
  h1{font-size:1.3rem;}.subtitle{margin-left:0;text-align:center;}
  .header{justify-content:center;}.button-group button{flex:1;min-width:120px;}}
.clip-toolbar{display:flex;align-items:center;gap:0.6rem;flex-wrap:wrap;
  padding:0.7rem 0.9rem;background:rgba(6,19,26,0.6);border:1px solid var(--border);
  border-radius:10px;margin-bottom:1rem;}
.clip-toolbar .tb-info{font-size:0.82rem;color:var(--text-muted);
  margin-left:auto;font-family:monospace;}
.clip-toolbar .tb-info.active{color:var(--accent);font-weight:600;}
.clip-toolbar label.chk{display:inline-flex;align-items:center;gap:0.4rem;margin:0;
  padding:0.35rem 0.6rem;background:rgba(20,184,166,0.12);
  border:1px solid var(--border-hi);border-radius:6px;cursor:pointer;
  font-size:0.82rem;color:var(--text);font-weight:500;transition:all 0.15s;}
.clip-toolbar label.chk:hover{background:rgba(20,184,166,0.25);}
.clip-toolbar input[type="checkbox"]{width:16px;height:16px;cursor:pointer;
  accent-color:var(--accent);margin:0;}
.clip-item{position:relative;transition:all 0.2s;}
.clip-item.selected{border-color:var(--accent) !important;
  box-shadow:0 0 0 2px rgba(34,211,238,0.35);}
.clip-checkbox{position:absolute;top:12px;right:12px;z-index:2;width:22px;height:22px;
  cursor:pointer;accent-color:var(--accent);}
.clip-limit-info{text-align:center;padding:0.8rem;color:var(--text-muted);font-size:0.85rem;}
.clip-limit-info button{margin-top:0.5rem;padding:0.5rem 1rem;font-size:0.85rem;}
</style>
</head>
<body>
<div class="container">
  <div class="header"><div class="logo">🎬</div><h1>AI Video Klip V4</h1></div>
  <p class="subtitle">Upload SRT → Gemini analisis → Klip viral otomatis</p>
  <div class="tab-nav">
    <button class="tab-button active" data-tab="buat">✂️ Buat Klip</button>
    <button class="tab-button" data-tab="files">📁 File Manager</button>
  </div>
  <div id="tab-buat" class="tab-content active">
    <div id="step1">
      <label><span class="step-num">1</span> File SRT <span style="color:var(--text-muted);font-weight:400;">(opsional — kalau kosong, auto-download dari YouTube)</span></label>
      <input type="file" id="srtFile" accept=".srt">
      <div id="srtStatus" class="status-msg"></div>
      <label><span class="step-num">2</span> URL Video YouTube</label>
      <input type="text" id="url" placeholder="https://www.youtube.com/watch?v=...">
      <label><span class="step-num">3</span> Rasio Output</label>
      <div style="background:rgba(6,19,26,0.55);border:1px solid var(--border);padding:0.7rem 1rem;border-radius:8px;font-size:0.85rem;color:var(--text-muted);margin-bottom:0.5rem;">
        📐 <b style="color:var(--pink)">1:1 (Square)</b> — crop tengah video, subtitle di 7.5% dari bawah
      </div>
      <label><span class="step-num">4</span> Musik Latar <span style="color:var(--text-muted);font-weight:400;">(opsional, volume 50%)</span></label>
      <input type="file" id="musicFile" accept="audio/*">
      <div id="musicStatus" class="status-msg"></div>
      <div class="button-group">
        <button id="btnAnalyze" onclick="analyzeSrt()">✨ Analisis SRT dengan Gemini</button>
      </div>
      <div id="analysisBox" class="analysis-box" style="display:none;">
        <span class="spinner"></span>
        <span id="analysisText">Menghubungi Gemini...</span>
        <span class="analysis-elapsed" id="analysisElapsed">0s</span>
      </div>
    </div>
    <div id="step2" style="display:none;">
      <hr class="divider">
      <h3 class="section-title">Klip yang Akan Dibuat</h3>
      <div id="clipsPreview"></div>
      <div class="button-group">
        <button class="btn-ghost" onclick="resetAnalysis()">← Kembali</button>
        <button class="btn-success" onclick="processClips()">🚀 Proses Klip Sekarang</button>
      </div>
    </div>
    <div id="progressArea" style="display:none;">
      <hr class="divider">
      <div class="progress-text" id="progressMsg">Memulai...</div>
      <div class="progress-wrap"><div class="progress-bar" id="progressBar"></div></div>
      <div style="text-align:center;font-size:0.82rem;color:var(--text-muted);padding:0.6rem;background:rgba(6,182,212,0.08);border-radius:6px;margin-top:0.6rem;line-height:1.5;">
        💡 <b>Boleh keluar browser</b> — proses tetap berjalan di server.<br>
        Buka kembali halaman ini kapan saja untuk cek progress.
      </div>
    </div>
    <div id="result"></div>
  </div>
  <div id="tab-files" class="tab-content">
    <h3 class="section-title">Video Tersimpan</h3>
    <div id="videoList"><p class="empty-note">Memuat...</p></div>
    <h3 class="section-title">Klip Tersimpan</h3>
    <div id="clipToolbar" class="clip-toolbar" style="display:none;">
      <label class="chk"><input type="checkbox" id="chkAll" onchange="toggleSelectAll(this)"> Pilih Semua</label>
      <button class="btn-danger btn-sm" onclick="deleteSelectedClips()" id="btnDeleteSelected" style="display:none;">🗑️ Hapus Terpilih</button>
      <button class="btn-danger btn-sm" onclick="deleteAllClips()" style="background:linear-gradient(135deg,#7f1d1d,#dc2626);">🗑️ Hapus Semua Klip</button>
      <span class="tb-info" id="clipToolbarInfo"></span>
    </div>
    <div id="clipList"><p class="empty-note">Memuat...</p></div>
  </div>
</div>
<div id="toast" class="toast"></div>
<script>
let parsed=[],selectedClips=new Set(),activeVideoFn=null,srtFn=null,musicFn=null,polling=null,timer=null;
document.querySelectorAll('.tab-button').forEach(b=>{b.addEventListener('click',function(){const t=this.dataset.tab;
  document.querySelectorAll('.tab-button').forEach(x=>x.classList.toggle('active',x.dataset.tab===t));
  document.querySelectorAll('.tab-content').forEach(x=>x.classList.toggle('active',x.id==='tab-'+t));
  if(t==='files')loadFiles();});});
function resetNavState(){activeVideoFn=null;parsed=[];selectedClips.clear();
  if(timer){clearInterval(timer);timer=null;}document.getElementById('analysisBox').style.display='none';}
document.getElementById('srtFile').addEventListener('change',function(){const f=this.files[0];
  const st=document.getElementById('srtStatus');if(!f){st.textContent='';window._srt=null;return;}
  window._srt=f;st.textContent='✓ '+f.name;st.className='status-msg ok';});
document.getElementById('musicFile').addEventListener('change',async function(){const f=this.files[0];
  const st=document.getElementById('musicStatus');if(!f){st.textContent='';musicFn=null;return;}
  st.textContent='⏳ Mengunggah musik...';st.className='status-msg';
  const fd=new FormData();fd.append('file',f);
  try{const r=await fetch('/upload_music',{method:'POST',body:fd});const d=await r.json();
    if(d.error){st.textContent='✗ '+d.error;st.className='status-msg err';musicFn=null;}
    else{musicFn=d.filename;st.textContent='✓ '+f.name+' (volume 50%)';st.className='status-msg ok';}}
  catch(e){st.textContent='✗ '+e.message;st.className='status-msg err';musicFn=null;}});
function parseOutput(text){const out=[];let cur=null;
  for(const raw of text.split('\n')){const line=raw.trim();if(!line)continue;
    const mC=line.match(/^(\d{1,3}:\d{2}(?::\d{2})?(?:\.\d+)?)\s*[-–—~]\s*(\d{1,3}:\d{2}(?::\d{2})?(?:\.\d+)?)$/);
    if(mC){if(cur)out.push(cur);cur={start:mC[1],end:mC[2],title:'',hook:'',hashtag:''};continue;}
    if(!cur)continue;
    const mT=line.match(/^(?:JUDUL|TITLE)\s*[:：]\s*(.+)$/i);
    if(mT){cur.title=mT[1].trim();continue;}
    const mH=line.match(/^(?:HOOK|HEADLINE)\s*[:：]\s*(.+)$/i);
    if(mH){cur.hook=mH[1].trim();continue;}
    const mHash=line.match(/^(?:HASHTAG|HASHTAGS|TAG)\s*[:：]\s*(.+)$/i);
    if(mHash){cur.hashtag=mHash[1].trim();continue;}}
  if(cur)out.push(cur);return out;}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function startAnalysis(){if(timer){clearInterval(timer);timer=null;}
  const box=document.getElementById('analysisBox');const txt=document.getElementById('analysisText');
  const el=document.getElementById('analysisElapsed');box.style.display='flex';box.className='analysis-box';
  txt.textContent='Menghubungi Gemini...';el.textContent='0s';const t0=Date.now();let dots=0;
  timer=setInterval(()=>{const s=Math.floor((Date.now()-t0)/1000);el.textContent=s+'s';
    if(s<3)txt.textContent='Menghubungi Gemini...';else if(s<10)txt.textContent='Menganalisis transkrip...';
    else if(s<20)txt.textContent='Mengidentifikasi momen viral...';
    else{dots=(dots+1)%4;txt.textContent='Menunggu respons'+'.'.repeat(dots)+' (SRT panjang butuh waktu)';}},500);}
function stopAnalysis(ok,msg){const box=document.getElementById('analysisBox');
  const txt=document.getElementById('analysisText');if(timer){clearInterval(timer);timer=null;}
  box.className='analysis-box '+(ok?'ok':'err');txt.textContent=msg||(ok?'Selesai!':'Gagal');
  document.getElementById('analysisElapsed').textContent='';
  if(ok)setTimeout(()=>{box.style.display='none';},3000);}
async function analyzeSrt(){const url=document.getElementById('url').value.trim();
  const st=document.getElementById('srtStatus');const btn=document.getElementById('btnAnalyze');
  if(!url){alert('Isi URL YouTube dulu.');return;}
  parsed=[];selectedClips.clear();activeVideoFn=null;
  document.getElementById('result').innerHTML='';document.getElementById('clipsPreview').innerHTML='';
  document.getElementById('step2').style.display='none';document.getElementById('step1').style.display='block';
  const hasSrtFile=!!window._srt;st.textContent=hasSrtFile?'':'⏳ Auto-download subtitle dari YouTube...';
  if(!hasSrtFile)st.className='status-msg';btn.disabled=true;startAnalysis();
  try{let r;if(hasSrtFile){const fd=new FormData();fd.append('file',window._srt);
      r=await fetch('/analyze_srt',{method:'POST',body:fd});}
    else{r=await fetch('/analyze_youtube',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({url:url})});}
    const d=await r.json();if(d.error){stopAnalysis(false,'✗ '+d.error);btn.disabled=false;return;}
    srtFn=d.srt_filename;parsed=parseOutput(d.analysis);
    if(!parsed.length){stopAnalysis(false,'✗ Format output tidak dikenali');btn.disabled=false;return;}
    stopAnalysis(true,'✓ '+parsed.length+' klip terdeteksi');renderPreview();
    document.getElementById('step1').style.display='none';document.getElementById('step2').style.display='block';
    window.scrollTo({top:0,behavior:'smooth'});}
  catch(e){stopAnalysis(false,'✗ '+e.message);btn.disabled=false;}}
function resetAnalysis(){if(timer){clearInterval(timer);timer=null;}
  document.getElementById('analysisBox').style.display='none';parsed=[];
  document.getElementById('step2').style.display='none';document.getElementById('step1').style.display='block';
  document.getElementById('btnAnalyze').disabled=false;document.getElementById('result').innerHTML='';
  document.getElementById('progressArea').style.display='none';}
function renderPreview(resetSelection){const c=document.getElementById('clipsPreview');
  if(!parsed.length){c.innerHTML='<p class="empty-note">Tidak ada klip.</p>';return;}
  if(resetSelection!==false){selectedClips=new Set();parsed.forEach((_,i)=>selectedClips.add(i));}
  let h='';h+='<div class="clip-toolbar" style="margin-bottom:1rem;">';
  h+='<label class="chk"><input type="checkbox" id="chkAllClips" checked onchange="toggleAllClips(this)"> Pilih Semua</label>';
  h+='<button class="btn-ghost btn-sm" onclick="selectNone()">Batal Pilih</button>';
  h+='<span class="tb-info active" id="clipSelectInfo">'+parsed.length+' dari '+parsed.length+' dipilih</span></div>';
  parsed.forEach((clip,i)=>{h+='<div class="clip-block" id="cb-'+i+'" style="position:relative;">';
    h+='<input type="checkbox" class="clip-checkbox" style="position:absolute;top:12px;right:12px;width:22px;height:22px;cursor:pointer;accent-color:#22d3ee;" checked onchange="toggleClip('+i+',this)">';
    h+='<div class="clip-block-header">Klip '+(i+1)+' — '+clip.start+' → '+clip.end+'</div>';
    if(clip.title||clip.hook||clip.hashtag){h+='<div class="clip-meta">';
      if(clip.title)h+='<div class="meta-row"><span class="meta-label">📌 Judul</span><span class="meta-value">'+esc(clip.title)+'</span><button class="meta-copy-btn" onclick="copyMeta('+i+',\'title\')">copy</button></div>';
      if(clip.hook)h+='<div class="meta-row"><span class="meta-label">🎣 Hook</span><span class="meta-value">'+esc(clip.hook)+'</span><button class="meta-copy-btn" onclick="copyMeta('+i+',\'hook\')">copy</button></div>';
      if(clip.hashtag)h+='<div class="meta-row"><span class="meta-label">#️⃣ Tag</span><span class="meta-value">'+esc(clip.hashtag)+'</span><button class="meta-copy-btn" onclick="copyMeta('+i+',\'hashtag\')">copy</button></div>';
      h+='</div>';}h+='</div>';});
  c.innerHTML=h;updateClipSelectInfo();}
function toggleAllClips(cb){if(cb.checked)parsed.forEach((_,i)=>selectedClips.add(i));
  else selectedClips.clear();
  document.querySelectorAll('.clip-checkbox').forEach((el)=>{el.checked=cb.checked;});
  document.querySelectorAll('.clip-block').forEach(el=>{el.style.opacity=cb.checked?'1':'0.5';});
  updateClipSelectInfo();}
function selectNone(){selectedClips.clear();
  document.querySelectorAll('.clip-checkbox').forEach(el=>el.checked=false);
  document.querySelectorAll('.clip-block').forEach(el=>el.style.opacity='0.5');
  document.getElementById('chkAllClips').checked=false;updateClipSelectInfo();}
function toggleClip(i,cb){if(cb.checked)selectedClips.add(i);else selectedClips.delete(i);
  const blk=document.getElementById('cb-'+i);if(blk)blk.style.opacity=cb.checked?'1':'0.5';
  updateClipSelectInfo();}
function updateClipSelectInfo(){const el=document.getElementById('clipSelectInfo');
  const all=document.getElementById('chkAllClips');if(!el)return;
  el.textContent=selectedClips.size+' dari '+parsed.length+' dipilih';
  if(all)all.checked=(selectedClips.size===parsed.length);}
function copyMeta(i,field){const c=parsed[i];if(!c)return;let t='';
  if(field==='title')t=c.title||'';else if(field==='hook')t=c.hook||'';else if(field==='hashtag')t=c.hashtag||'';
  if(!t){showToast('Kosong',true);return;}copyText(t);}
async function processClips(){const url=document.getElementById('url').value.trim();
  if(!activeVideoFn&&!url){alert('Masukkan URL YouTube dulu, atau pilih video dari File Manager.');return;}
  if(!parsed.length){alert('Belum ada klip.');return;}
  if(selectedClips.size===0){alert('Pilih minimal 1 klip.');return;}
  const clipsData=[];parsed.forEach((c,i)=>{if(selectedClips.has(i)){
    clipsData.push({start:c.start,end:c.end,meta:{title:c.title,hook:c.hook,hashtag:c.hashtag}});}});
  const allClipsData=parsed.map(c=>({start:c.start,end:c.end,meta:{title:c.title,hook:c.hook,hashtag:c.hashtag}}));
  const payload={clips:clipsData,all_clips:allClipsData};
  if(activeVideoFn)payload.video_filename=activeVideoFn;else if(url)payload.url=url;
  else{alert('URL kosong.');return;}
  if(srtFn)payload.srt_filename=srtFn;if(musicFn)payload.music_filename=musicFn;
  document.getElementById('progressArea').style.display='block';
  document.getElementById('progressMsg').textContent='Mengirim permintaan...';
  document.getElementById('progressBar').style.width='0%';document.getElementById('result').innerHTML='';
  try{const endpoint=activeVideoFn?'/process_existing':'/process';
    const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify(payload)});const d=await r.json();
    if(d.error){showErr(d.error);return;}const jid=d.job_id;
    if(polling){clearInterval(polling);polling=null;}
    polling=setInterval(async()=>{try{const sr=await fetch('/status/'+jid);const sd=await sr.json();
      if(sd.error){clearInterval(polling);showErr(sd.error);return;}
      document.getElementById('progressBar').style.width=(sd.progress||0)+'%';
      document.getElementById('progressMsg').textContent=sd.message||'Memproses...';
      if(sd.status==='done'){clearInterval(polling);
        document.getElementById('progressArea').style.display='none';
        showResult(sd.clips);loadFiles();}
      else if(sd.status==='error'){clearInterval(polling);showErr(sd.error||'Terjadi kesalahan');}}
      catch(e){clearInterval(polling);showErr('Gagal: '+e.message);}},1000);}
  catch(e){showErr('Error: '+e.message);}}
function showResult(clips){const rd=document.getElementById('result');
  if(!clips||!clips.length){rd.innerHTML='<p class="status-msg err">✗ Tidak ada klip yang berhasil dibuat. Cek log server.</p>';return;}
  let h='<hr class="divider">';h+='<div class="success-banner">';
  h+='<h3>✓ '+clips.length+' Klip Berhasil Dibuat</h3>';
  h+='<p>Klip tersimpan di File Manager. Putar langsung di bawah atau unduh.</p></div>';
  clips.forEach((cl,i)=>{h+='<div class="file-card" style="border-color:var(--success);">';
    h+='<video controls playsinline preload="metadata"><source src="'+cl.stream_url+'" type="video/mp4"></video>';
    h+='<div class="file-card-info"><div class="filename">🎞️ Klip '+(i+1)+' <small>'+cl.filename+'</small></div>';
    h+=renderMeta(cl.meta);h+='<div class="file-actions"><a href="'+cl.download_url+'" download>⬇️ Unduh</a></div></div></div>';});
  h+='<div style="text-align:center;margin-top:1rem;">';
  h+='<button class="btn-ghost" onclick="document.querySelector(\'.tab-button[data-tab=files]\').click()">📁 Buka File Manager</button></div>';
  rd.innerHTML=h;setTimeout(()=>rd.scrollIntoView({behavior:'smooth',block:'start'}),200);}
function renderMeta(m){if(!m||(!m.title&&!m.hook&&!m.hashtag))return '';
  let h='<div class="clip-meta-display">';
  if(m.title)h+='<div class="meta-row"><span class="meta-label">📌 Judul</span><span class="meta-value">'+esc(m.title)+'</span></div>';
  if(m.hook)h+='<div class="meta-row"><span class="meta-label">🎣 Hook</span><span class="meta-value">'+esc(m.hook)+'</span></div>';
  if(m.hashtag)h+='<div class="meta-row"><span class="meta-label">#️⃣ Tag</span><span class="meta-value">'+esc(m.hashtag)+'</span></div>';
  h+='</div>';return h;}
function showErr(msg){document.getElementById('progressArea').style.display='none';
  document.getElementById('result').innerHTML='<p class="status-msg err">✗ '+esc(msg)+'</p>';}
async function loadFiles(){try{const r=await fetch('/files');const d=await r.json();
  renderVideos(d.videos);renderClips(d.clips);}catch(e){console.error(e);}}
function renderVideos(v){const c=document.getElementById('videoList');
  if(!v||!v.length){c.innerHTML='<p class="empty-note">Belum ada video.</p>';return;}
  let h='';v.forEach(x=>{const badge=x.has_srt?'<span class="badge-srt">SRT tersimpan</span>':'';
    h+='<div class="file-card"><video controls playsinline preload="metadata"><source src="'+x.stream_url+'" type="video/mp4"></video>';
    h+='<div class="file-card-info"><div class="filename">'+esc(x.title)+' <small>'+x.filename+'</small>'+badge+'</div>';
    h+='<div class="file-actions">';
    h+='<button class="btn-blue btn-sm" onclick="reprocessVideo(\''+x.filename+'\')">✂️ Potong Ulang</button>';
    h+='<a href="'+x.download_url+'" download>⬇️ Unduh</a>';
    h+='<button class="btn-danger btn-sm" onclick="delFile(\'video\',\''+x.filename+'\')">🗑️ Hapus</button>';
    h+='</div></div></div>';});c.innerHTML=h;}
let allClips=[],showAllClips=false;const CLIP_PAGE_SIZE=6;
function renderClips(c){const el=document.getElementById('clipList');
  const toolbar=document.getElementById('clipToolbar');allClips=c||[];
  if(!c||!c.length){el.innerHTML='<p class="empty-note">Belum ada klip.</p>';toolbar.style.display='none';return;}
  toolbar.style.display='flex';updateToolbarInfo();
  const display=showAllClips?allClips:allClips.slice(0,CLIP_PAGE_SIZE);let h='';
  display.forEach((x)=>{h+='<div class="file-card clip-item" id="clip-'+x.filename+'">';
    h+='<input type="checkbox" class="clip-checkbox" onchange="onClipCheck(this)" data-fn="'+x.filename+'">';
    h+='<video controls playsinline preload="metadata"><source src="'+x.stream_url+'" type="video/mp4"></video>';
    h+='<div class="file-card-info"><div class="filename">'+x.filename+'</div>';
    h+=renderMeta(x.meta);
    h+='<div class="file-actions"><a href="'+x.download_url+'" download>⬇️ Unduh</a>';
    h+='<button class="btn-danger btn-sm" onclick="delFile(\'clip\',\''+x.filename+'\')">🗑️ Hapus</button>';
    h+='</div></div></div>';});
  if(!showAllClips&&allClips.length>CLIP_PAGE_SIZE){
    h+='<div class="clip-limit-info">Menampilkan '+CLIP_PAGE_SIZE+' dari '+allClips.length+' klip.';
    h+='<br><button class="btn-ghost btn-sm" onclick="toggleShowAll()">Tampilkan Semua ('+allClips.length+')</button></div>';}
  else if(showAllClips&&allClips.length>CLIP_PAGE_SIZE){
    h+='<div class="clip-limit-info"><button class="btn-ghost btn-sm" onclick="toggleShowAll()">↑ Sembunyikan (tampil '+CLIP_PAGE_SIZE+')</button></div>';}
  el.innerHTML=h;}
function toggleShowAll(){showAllClips=!showAllClips;renderClips(allClips);}
function onClipCheck(cb){const fn=cb.dataset.fn;const item=document.getElementById('clip-'+fn);
  if(item)item.classList.toggle('selected',cb.checked);updateToolbarInfo();}
function getSelectedFilenames(){return Array.from(document.querySelectorAll('.clip-checkbox:checked')).map(cb=>cb.dataset.fn);}
function updateToolbarInfo(){const info=document.getElementById('clipToolbarInfo');
  const btnDel=document.getElementById('btnDeleteSelected');const sel=getSelectedFilenames();
  if(sel.length>0){info.textContent=sel.length+' dipilih';info.classList.add('active');
    btnDel.style.display='inline-block';}
  else{info.textContent=allClips.length+' klip';info.classList.remove('active');btnDel.style.display='none';}
  const chkAll=document.getElementById('chkAll');
  if(chkAll){const visible=document.querySelectorAll('.clip-checkbox');
    const checked=document.querySelectorAll('.clip-checkbox:checked');
    chkAll.checked=visible.length>0&&visible.length===checked.length;}}
function toggleSelectAll(cb){document.querySelectorAll('.clip-checkbox').forEach(x=>{
    x.checked=cb.checked;const item=document.getElementById('clip-'+x.dataset.fn);
    if(item)item.classList.toggle('selected',cb.checked);});updateToolbarInfo();}
async function deleteSelectedClips(){const fns=getSelectedFilenames();
  if(!fns.length){showToast('Belum ada yang dipilih',true);return;}
  if(!confirm('Hapus '+fns.length+' klip terpilih?'))return;
  try{const r=await fetch('/delete/clips_batch',{method:'POST',
    headers:{'Content-Type':'application/json'},body:JSON.stringify({filenames:fns})});
    const d=await r.json();
    if(d.success){showToast('✓ '+d.deleted+' klip dihapus');
      document.getElementById('chkAll').checked=false;loadFiles();}
    else alert('Gagal: '+(d.error||''));}catch(e){alert('Error: '+e.message);}}
async function deleteAllClips(){if(!allClips.length){showToast('Tidak ada klip',true);return;}
  if(!confirm('⚠️ Hapus SEMUA '+allClips.length+' klip? Tidak bisa dibatalkan!'))return;
  if(!confirm('Yakin? Konfirmasi sekali lagi.'))return;
  try{const r=await fetch('/delete/clips_batch',{method:'POST',
    headers:{'Content-Type':'application/json'},body:JSON.stringify({all:true})});
    const d=await r.json();
    if(d.success){showToast('✓ '+d.deleted+' klip dihapus');
      document.getElementById('chkAll').checked=false;loadFiles();}
    else alert('Gagal: '+(d.error||''));}catch(e){alert('Error: '+e.message);}}
async function delFile(type,fn){if(!confirm('Hapus '+fn+'?'))return;
  try{const r=await fetch('/delete/'+type+'/'+fn,{method:'DELETE'});const d=await r.json();
    if(d.success){showToast('Terhapus');loadFiles();}else alert('Gagal: '+(d.error||''));}
  catch(e){alert('Error: '+e.message);}}
function copyText(t){try{const ta=document.createElement('textarea');ta.value=t;
    ta.style.position='fixed';ta.style.top='-9999px';document.body.appendChild(ta);
    ta.select();ta.setSelectionRange(0,t.length);const ok=document.execCommand('copy');
    document.body.removeChild(ta);showToast(ok?'✓ Disalin!':'✗ Gagal',!ok);}
  catch(e){showToast('✗ '+e.message,true);}}
function showToast(msg,err){const t=document.getElementById('toast');t.textContent=msg;
  t.className='toast show'+(err?' err':'');
  setTimeout(()=>{t.classList.remove('show');},2000);}
async function reprocessVideo(fn){try{const r=await fetch('/video_history/'+fn);const d=await r.json();
    if(d.error){alert(d.error);return;}activeVideoFn=fn;
    document.getElementById('url').value='';
    document.getElementById('url').placeholder='Potong ulang: '+d.title;
    if(d.srt_filename)srtFn=d.srt_filename;
    if(d.last_clips&&d.last_clips.length){parsed=d.last_clips.map(c=>({start:c.start,end:c.end,
      title:c.meta?c.meta.title||'':'',hook:c.meta?c.meta.hook||'':'',hashtag:c.meta?c.meta.hashtag||'':''}));
      renderPreview();document.getElementById('step1').style.display='none';
      document.getElementById('step2').style.display='block';
      document.querySelector('.tab-button[data-tab="buat"]').click();
      setTimeout(()=>window.scrollTo({top:0,behavior:'smooth'}),100);
      showToast('Riwayat klip dimuat: '+d.last_clips.length+' klip');}
    else{resetAnalysis();document.querySelector('.tab-button[data-tab="buat"]').click();
      alert('Video ini belum punya riwayat klip. Upload SRT baru untuk analisis.');}}
  catch(e){alert('Error: '+e.message);}}
async function checkActiveJob(){try{const r=await fetch('/active_job');const d=await r.json();
    if(!d.active)return;const buatTab=document.querySelector('.tab-button[data-tab="buat"]');
    if(buatTab)buatTab.click();document.getElementById('step1').style.display='none';
    document.getElementById('step2').style.display='none';
    document.getElementById('progressArea').style.display='block';
    document.getElementById('progressBar').style.width=(d.progress||0)+'%';
    document.getElementById('progressMsg').textContent=d.message||'Memproses...';
    const btn=document.getElementById('btnAnalyze');if(btn)btn.disabled=true;
    if(d.status==='done'||d.status==='error'){await handleJobDone(d.job_id);return;}
    if(polling){clearInterval(polling);polling=null;}
    polling=setInterval(async()=>{try{const sr=await fetch('/status/'+d.job_id);const sd=await sr.json();
      if(sd.error){clearInterval(polling);showErr(sd.error);return;}
      document.getElementById('progressBar').style.width=(sd.progress||0)+'%';
      document.getElementById('progressMsg').textContent=sd.message||'Memproses...';
      if(sd.status==='done'){clearInterval(polling);await handleJobDone(d.job_id);}
      else if(sd.status==='error'){clearInterval(polling);
        document.getElementById('progressArea').style.display='none';
        showErr(sd.error||'Terjadi kesalahan');document.getElementById('btnAnalyze').disabled=false;}}
      catch(e){clearInterval(polling);console.error(e);}},1500);}
  catch(e){console.error('[resume] Error:',e);}}
async function handleJobDone(jobId){try{const sr=await fetch('/status/'+jobId);const sd=await sr.json();
    document.getElementById('progressArea').style.display='none';
    showResult(sd.clips||[]);loadFiles();await fetch('/active_job/clear',{method:'POST'});
    const btn=document.getElementById('btnAnalyze');if(btn)btn.disabled=false;}
  catch(e){console.error(e);document.getElementById('btnAnalyze').disabled=false;}}
window.addEventListener('load',async()=>{await loadFiles();await checkActiveJob();});
</script>
</body>
</html>
AIVK_EOF_HTML

STEP="menulis start.sh"
cat > "$INSTALL_DIR/start.sh" <<'AIVK_EOF_START'
#!/bin/sh
# Menjalankan AI Video Klip V4 (dipakai service procd, bisa juga manual: sh start.sh)
cd "$(cd "$(dirname "$0")" && pwd)" || exit 1

export PATH="$PWD/bin:$PATH"
export PYTHONPATH="$PWD/pylibs${PYTHONPATH:+:$PYTHONPATH}"
export AIVK_DATA_DIR="$PWD"
export TMPDIR="$PWD/tmp"
export HOME="$PWD"
export XDG_CACHE_HOME="$PWD/cache"
[ -d "$PWD/fonts" ] && export AIVK_FONTS_DIR="$PWD/fonts"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"

for bin in ffmpeg ffprobe yt-dlp python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "❌ '$bin' belum terpasang. Jalankan ulang install.sh"
        exit 1
    fi
done

exec python3 app.py
AIVK_EOF_START

STEP="menulis update-ytdlp.sh"
cat > "$INSTALL_DIR/update-ytdlp.sh" <<'AIVK_EOF_UPD'
#!/bin/sh
# Update yt-dlp (jalankan kalau download/subtitle YouTube mendadak gagal)
D="$(cd "$(dirname "$0")" && pwd)"
TMPDIR="$D/tmp" python3 -m pip install --no-cache-dir --upgrade --target "$D/pylibs" yt-dlp \
  && "$D/bin/yt-dlp" --version
AIVK_EOF_UPD
chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/update-ytdlp.sh" 2>/dev/null

# validasi sintaks python sebelum lanjut
STEP="validasi app.py"
python3 -m py_compile "$INSTALL_DIR/app.py" || die "app.py tidak valid."
rm -rf "$INSTALL_DIR/__pycache__"

# ---------- Gemini API key (.env) ----------
STEP="setup .env"
ENV_FILE="$INSTALL_DIR/.env"
CURRENT_KEY=""
[ -f "$ENV_FILE" ] && CURRENT_KEY="$(grep -m1 '^GEMINI_API_KEY=' "$ENV_FILE" | cut -d= -f2-)"
case "$CURRENT_KEY" in ISI_*) CURRENT_KEY="" ;; esac

NEW_KEY="${GEMINI_API_KEY:-}"
echo ""
echo "🔑 Gemini API Key (gratis di https://aistudio.google.com/apikey)"
if [ -z "$NEW_KEY" ]; then
    if [ -n "$CURRENT_KEY" ]; then
        echo "   Sudah ada key tersimpan (diakhiri ...$(echo "$CURRENT_KEY" | awk '{print substr($0,length($0)-5)}'))."
        printf "   Ganti dengan key baru? (kosongkan untuk tetap pakai yang lama): "
    else
        printf "   Masukkan GEMINI_API_KEY (boleh kosong, isi nanti di .env): "
    fi
    { read -r NEW_KEY < /dev/tty; } 2>/dev/null || { NEW_KEY=""; echo ""; }
fi

if [ -n "$NEW_KEY" ]; then
    printf 'GEMINI_API_KEY=%s\n' "$NEW_KEY" > "$ENV_FILE"
    echo "   ✓ Key disimpan ke $ENV_FILE"
elif [ -n "$CURRENT_KEY" ]; then
    echo "   ✓ Tetap pakai key lama."
else
    echo "GEMINI_API_KEY=ISI_GEMINI_API_KEY_DISINI" > "$ENV_FILE"
    warn "Key belum diisi. Edit $ENV_FILE lalu: /etc/init.d/$SERVICE restart"
fi
chmod 600 "$ENV_FILE" 2>/dev/null

# ---------- service procd (auto-start saat boot) ----------
STEP="membuat service procd"
cat > "/etc/init.d/$SERVICE" <<'AIVK_EOF_INIT'
#!/bin/sh /etc/rc.common
# AI Video Klip V4 — service procd
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    # tunggu storage ter-mount (maks ~3 menit) baru jalankan app
    procd_set_param command /bin/sh -c 'n=0; while [ ! -f "@INSTALL_DIR@/app.py" ] && [ "$n" -lt 90 ]; do sleep 2; n=$((n+1)); done; exec /bin/sh "@INSTALL_DIR@/start.sh"'
    procd_set_param env AIVK_PORT=@PORT@
    procd_set_param respawn 3600 10 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
AIVK_EOF_INIT
sed -i -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" -e "s|@PORT@|$PORT|g" "/etc/init.d/$SERVICE"
chmod +x "/etc/init.d/$SERVICE"

STEP="menjalankan service"
"/etc/init.d/$SERVICE" enable
"/etc/init.d/$SERVICE" restart
sleep 6

LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)"
[ -z "$LAN_IP" ] && LAN_IP="$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
[ -z "$LAN_IP" ] && LAN_IP="IP-ROUTER"

UP=0
for i in 1 2 3 4 5; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then UP=1; break; fi
    sleep 3
done

echo ""
echo "========================================"
if [ "$UP" = "1" ]; then
    echo "✅ INSTALASI SELESAI — aplikasi sudah jalan."
else
    echo "⚠️  Terpasang, tapi web belum merespons. Cek log: logread | tail -n 40"
fi
echo "========================================"
echo "Buka di browser : http://$LAN_IP:$PORT"
echo "Folder data     : $INSTALL_DIR"
echo "  ├─ downloads/      (video asli dari YouTube)"
echo "  ├─ clips/          (hasil klip)"
echo "  ├─ uploads_srt/    (subtitle)"
echo "  └─ uploads_music/  (musik latar)"
echo ""
echo "Perintah berguna:"
echo "  /etc/init.d/$SERVICE restart|stop|start"
echo "  logread -e python3 | tail     (lihat log)"
echo "  sh $INSTALL_DIR/update-ytdlp.sh   (update yt-dlp kalau YouTube berubah)"
echo "  sh install.sh uninstall           (hapus service)"
