import sys
import os
import json
import tempfile
import traceback
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

# Force UTF-8 output to avoid cp950 encoding errors with Chinese characters
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def emit_json(data):
    try:
        print(json.dumps(data, ensure_ascii=False), flush=True)
    except UnicodeEncodeError:
        print(json.dumps(data, ensure_ascii=True), flush=True)


def cmd_rss_list(args):
    import requests
    url = args[0]
    resp = requests.get(url, timeout=30, headers={
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    })
    resp.raise_for_status()
    root = ET.fromstring(resp.content)
    ns = {'itunes': 'http://www.itunes.com/dtds/podcast-1.0.dtd'}
    channel = root.find('channel')
    if channel is None:
        channel = root
    episodes = []
    for item in channel.findall('.//item'):
        title_el = item.find('title')
        title = title_el.text.strip() if title_el is not None and title_el.text else ''
        pub_date_el = item.find('pubDate')
        pub_date = pub_date_el.text.strip() if pub_date_el is not None and pub_date_el.text else ''
        enclosure = item.find('enclosure')
        audio_url = enclosure.get('url', '') if enclosure is not None else ''
        audio_type = enclosure.get('type', '') if enclosure is not None else ''
        duration_el = item.find('{http://www.itunes.com/dtds/podcast-1.0.dtd}duration')
        duration = ''
        if duration_el is not None and duration_el.text:
            duration = duration_el.text.strip()
        description_el = item.find('description')
        description = ''
        if description_el is not None and description_el.text:
            description = description_el.text.strip()
        episodes.append({
            'title': title,
            'pub_date': pub_date,
            'audio_url': audio_url,
            'audio_type': audio_type,
            'duration': duration,
            'description': description,
        })
    channel_title_el = channel.find('title')
    channel_title = channel_title_el.text.strip() if channel_title_el is not None and channel_title_el.text else ''
    emit_json({'type': 'rss_list', 'title': channel_title, 'episodes': episodes})


def cmd_rss_get_audio(args):
    """Get audio URL from a podcast RSS by episode index"""
    url = args[0]
    index = int(args[1])
    import requests
    resp = requests.get(url, timeout=30, headers={
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    })
    resp.raise_for_status()
    root = ET.fromstring(resp.content)
    items = root.findall('.//item')
    if index >= len(items):
        emit_json({'type': 'error', 'message': f'Episode index {index} out of range'})
        return
    item = items[index]
    enclosure = item.find('enclosure')
    if enclosure is None:
        emit_json({'type': 'error', 'message': 'No enclosure found'})
        return
    audio_url = enclosure.get('url', '')
    title_el = item.find('title')
    title = title_el.text.strip() if title_el is not None and title_el.text else f'episode_{index}'
    emit_json({'type': 'rss_audio', 'title': title, 'audio_url': audio_url})


def cmd_rss_download(args):
    """Download a single podcast episode (part-file + retry, no half-file cache)"""
    url = args[0]
    output_path = args[1]
    import requests
    import time
    parent = os.path.dirname(output_path) or '.'
    os.makedirs(parent, exist_ok=True)
    part_path = output_path + '.part'
    last_err = ''
    for attempt in range(2):
        try:
            resp = requests.get(url, stream=True, timeout=60, headers={
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            })
            resp.raise_for_status()
            total = int(resp.headers.get('content-length', 0))
            downloaded = 0
            with open(part_path, 'wb') as f:
                for chunk in resp.iter_content(chunk_size=8192):
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total > 0:
                        pct = downloaded / total * 100
                        emit_json({'type': 'progress', 'downloaded': downloaded, 'total': total, 'percent': round(pct, 1)})
            if total > 0 and downloaded < total:
                raise IOError(f'truncated: {downloaded}/{total}')
            os.replace(part_path, output_path)
            emit_json({'type': 'complete', 'path': output_path})
            return
        except Exception as e:
            last_err = str(e)
            try:
                if os.path.exists(part_path):
                    os.remove(part_path)
            except Exception:
                pass
            time.sleep(3 * (attempt + 1))
    emit_json({'type': 'error', 'message': f'rss-download failed: {last_err}'})


def cmd_download_song(args):
    """Download a song using existing core/downloader.py"""
    song_name = args[0]
    library_path = args[1]
    audio_format = args[2] if len(args) > 2 else 'mp3'
    from utils.config import CONFIG_DIR, load_config
    config = load_config()
    from core.downloader import download_song
    result = download_song(song_name, library_path, audio_format, lambda msg: emit_json({
        'type': 'log', 'message': msg
    }), file_list=[], config=config)
    if result:
        emit_json({'type': 'complete', 'path': result})
    else:
        emit_json({'type': 'error', 'message': f'Failed to download: {song_name}'})


def cmd_download_youtube(args):
    """Download audio from a YouTube URL"""
    url = args[0]
    output_path = args[1]
    audio_format = args[2] if len(args) > 2 else 'mp3'

    import yt_dlp
    from utils.helpers import sanitize_filename

    def progress_hook(d):
        if d['status'] == 'downloading':
            total = d.get('total_bytes') or d.get('total_bytes_estimate') or 0
            downloaded = d.get('downloaded_bytes', 0)
            speed = d.get('speed', 0)
            pct = round(downloaded / total * 100, 1) if total > 0 else 0
            emit_json({'type': 'progress', 'downloaded': downloaded, 'total': total, 'percent': pct, 'speed': speed})
        elif d['status'] == 'finished':
            emit_json({'type': 'log', 'message': 'Processing audio...'})

    ydl_opts = {
        'format': 'bestaudio/best',
        # splitext 只換副檔名：replace 會連資料夾名裡的 .mp3 一起改掉。
        'outtmpl': os.path.splitext(output_path)[0] + '.%(ext)s',
        'quiet': True,
        'no_warnings': True,
        'extract_audio': True,
        'postprocessors': [{
            'key': 'FFmpegExtractAudio',
            'preferredcodec': audio_format,
            'preferredquality': '320',
        }],
        'progress_hooks': [progress_hook],
        'keepvideo': False,
        'windowsfilenames': True,
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
        final_path = output_path
        if os.path.exists(final_path):
            emit_json({'type': 'complete', 'path': final_path})
        else:
            base = os.path.splitext(os.path.basename(output_path))[0]
            dir_path = os.path.dirname(output_path)
            candidates = [f for f in os.listdir(dir_path) if f.startswith(base) and f.endswith(f'.{audio_format}')]
            if candidates:
                emit_json({'type': 'complete', 'path': os.path.join(dir_path, candidates[0])})
            else:
                emit_json({'type': 'error', 'message': 'Output file not found'})
    except Exception as e:
        emit_json({'type': 'error', 'message': str(e)})


def cmd_download_spotdl(args):
    """Download a song via spotDL to a separate spotdl_downloads folder"""
    song_url = args[0]
    output_dir = args[1]
    audio_format = args[2] if len(args) > 2 else 'mp3'
    output_template = os.path.join(output_dir, '{artist} - {title}.{ext}')
    from core.downloader import download_with_spotdl
    config = {'format': audio_format, 'ffmpeg_path': 'bin/ffmpeg.exe', 'overwrite': 'skip'}
    result = download_with_spotdl(song_url, output_template, config)
    if result:
        emit_json({'type': 'complete', 'path': str(result)})
    else:
        emit_json({'type': 'error', 'message': f'spotDL failed: {song_url}'})


def cmd_list_missing(args):
    """List all songs missing a specific format (mp3/flac) across all playlists"""
    target_format = args[0] if args else 'mp3'
    from utils.config import load_config, get_data_file
    import glob
    import hashlib

    config = load_config()
    library_path = config.get('library_path', '')
    if not library_path:
        emit_json({'type': 'error', 'message': 'Library path not configured'})
        return

    search_pattern = os.path.join(library_path, "**", "*")
    all_files = glob.glob(search_pattern, recursive=True)
    audio_files = [f for f in all_files if f.lower().endswith(('.mp3', '.m4a', '.flac', '.wav'))]

    from core.library import build_library_index, find_song_exact_format, parse_playlist, is_internal_playlist_name
    library_index = build_library_index(audio_files)

    playlist_dir = os.path.join(library_path, 'playlists')
    if not os.path.exists(playlist_dir):
        emit_json({'type': 'error', 'message': 'Playlists directory not found'})
        return

    playlist_files = [os.path.join(playlist_dir, f) for f in os.listdir(playlist_dir)
                      if f.endswith('.m3u8') and not is_internal_playlist_name(f)]

    # Load failed FLAC cache (only relevant for flac format)
    failed_cache = {}
    if target_format == 'flac':
        try:
            cache_file = get_data_file('failed_flac.json')
            if os.path.exists(cache_file):
                with open(cache_file, 'r', encoding='utf-8') as f:
                    failed_cache = json.load(f)
        except Exception as e:
            # 損毀不可靜默吞掉（否則無限重試下載）：備份後重置。
            try:
                bak = cache_file + '.corrupt.bak'
                if os.path.exists(cache_file):
                    os.replace(cache_file, bak)
                emit_json({'type': 'log', 'message': f'failed_flac.json 損毀已備份重置: {e}'})
            except Exception:
                pass
            failed_cache = {}

    missing_songs = []
    seen = set()

    for pl_file in playlist_files:
        playlist_name = os.path.splitext(os.path.basename(pl_file))[0]
        songs = parse_playlist(pl_file)
        for song_name in songs:
            norm_name = song_name.strip().lower()
            song_key = hashlib.md5(norm_name.encode('utf-8')).hexdigest()

            if target_format == 'flac' and song_key in failed_cache:
                continue

            if find_song_exact_format(song_name, target_format, library_index):
                continue

            if song_key in seen:
                continue
            seen.add(song_key)

            artist_hint = ''
            if ' - ' in song_name:
                parts = song_name.split(' - ', 1)
                artist_hint = parts[1].strip()

            missing_songs.append({
                'name': song_name,
                'playlist': playlist_name,
                'artist_hint': artist_hint,
            })

    emit_json({'type': 'missing_list', 'format': target_format, 'songs': missing_songs, 'total_missing': len(missing_songs)})


def cmd_batch_download(args):
    """Download missing songs in specified format"""
    target_format = args[0] if len(args) > 0 else 'mp3'
    songs_json = args[1] if len(args) > 1 else '[]'
    songs = json.loads(songs_json)

    from utils.config import load_config, get_data_file
    config = load_config()
    library_path = config.get('library_path', '')
    if not library_path:
        emit_json({'type': 'error', 'message': 'Library path not configured'})
        return

    use_dab_lossless = config.get('dab_use_lossless', False) and target_format == 'flac'
    use_dab_metadata = config.get('dab_use_metadata', False) and target_format == 'flac'
    dab_credentials = None
    if use_dab_lossless:
        dab_email = config.get('dab_email', '')
        dab_password = config.get('dab_password', '')
        if dab_email and dab_password:
            dab_credentials = {'email': dab_email, 'password': dab_password}

    total = len(songs)
    successful = 0
    failed = 0

    emit_json({'type': 'batch_start', 'total': total, 'format': target_format})

    for i, song in enumerate(songs):
        try:
            song_name = song.get('name', '') if isinstance(song, dict) else str(song)
        except Exception:
            failed += 1
            continue
        if not song_name:
            failed += 1
            emit_json({'type': 'log', 'message': '❌ 空歌曲名，跳過'})
            continue
        emit_json({'type': 'batch_progress', 'index': i, 'total': total,
                   'song': song_name, 'format': target_format,
                   'percent': round(i / total * 100, 1) if total > 0 else 0})

        from core.downloader import download_song
        try:
            result = download_song(
                song_name, library_path, target_format, lambda msg: emit_json({
                    'type': 'log', 'message': msg
                }), file_list=[], config=config,
                use_dab_lossless=use_dab_lossless, use_dab_metadata=use_dab_metadata,
                dab_credentials=dab_credentials
            )
        except Exception as e:
            # 單首例外不可中斷整批。
            failed += 1
            emit_json({'type': 'log', 'message': f'❌ {song_name} - 例外: {e}'})
            continue

        if result and os.path.exists(result):
            successful += 1
            emit_json({'type': 'log', 'message': f'✅ {song_name} - {target_format.upper()} 下載成功'})
            if target_format == 'flac':
                import hashlib
                norm_name = song_name.strip().lower()
                song_key = hashlib.md5(norm_name.encode('utf-8')).hexdigest()
                try:
                    cache_file = get_data_file('failed_flac.json')
                    if os.path.exists(cache_file):
                        with open(cache_file, 'r', encoding='utf-8') as f:
                            fc = json.load(f)
                        if song_key in fc:
                            del fc[song_key]
                            with open(cache_file, 'w', encoding='utf-8') as f:
                                json.dump(fc, f, ensure_ascii=False, indent=2)
                except:
                    pass
        else:
            failed += 1
            emit_json({'type': 'log', 'message': f'❌ {song_name} - {target_format.upper()} 下載失敗'})

    emit_json({'type': 'batch_complete', 'successful': successful, 'failed': failed, 'format': target_format})


def cmd_normalize_mp3_lufs(args):
    """Normalize MP3s deviating from -14 LUFS. Handles sentinel values (-99) by measuring first."""
    import shutil

    from utils.config import load_config, get_data_file
    config = load_config()
    library_path = config.get('library_path', '')
    if not library_path:
        emit_json({'type': 'error', 'message': 'Library path not configured'})
        return

    cache_file = get_data_file('mp3_lufs_cache.json')
    if not os.path.exists(cache_file):
        emit_json({'type': 'log', 'message': 'MP3 LUFS 快取不存在，跳過 normalize'})
        return

    with open(cache_file, 'r', encoding='utf-8') as f:
        cache = json.load(f)

    target = -14.0
    ffmpeg_path = shutil.which('ffmpeg') or config.get('ffmpeg_path', 'ffmpeg')
    sentinel = -99

    # Phase 1: measure sentinel values and find files that need normalization
    need_measure = {k: v for k, v in cache.items() if abs(float(v) - sentinel) < 0.5}
    need_normalize = {k: float(v) for k, v in cache.items() if abs(float(v) - target) > 2.0 and k not in need_measure}

    if need_measure:
        emit_json({'type': 'log', 'message': f'測量 {len(need_measure)} 個未快取的 MP3...'})
        done = 0
        for rel_path in need_measure:
            abs_path = os.path.join(library_path, rel_path)
            if not os.path.exists(abs_path):
                cache[rel_path] = target
                done += 1
                continue
            # Quick measurement with ffmpeg loudnorm analysis (first 30s)
            cmd = [ffmpeg_path, '-t', '30', '-i', abs_path,
                   '-af', 'loudnorm=print_format=json',
                   '-f', 'null', 'NUL', '-hide_banner', '-y']
            try:
                r = subprocess.run(cmd, capture_output=True, timeout=120,
                                   encoding='utf-8', errors='replace')
                out = r.stderr
                json_start = out.rfind('{')
                if json_start >= 0:
                    try:
                        data, _ = json.JSONDecoder().raw_decode(out[json_start:])
                        input_i = data.get('input_i')
                        if input_i is not None:
                            measured = float(input_i)
                            cache[rel_path] = measured
                            if abs(measured - target) > 2.0:
                                need_normalize[rel_path] = measured
                            done += 1
                            if done % 25 == 0:
                                emit_json({'type': 'progress', 'percent': round(done / len(need_measure) * 100, 1)})
                            continue
                    except:
                        pass
            except:
                pass
            cache[rel_path] = target
            done += 1

    if not need_normalize:
        emit_json({'type': 'log', 'message': '所有 MP3 已在 -14±2 LUFS 範圍內，無需 normalize'})
        # Save updated cache
        with open(cache_file, 'w', encoding='utf-8') as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)
        return

    emit_json({'type': 'log', 'message': f'Normalize {len(need_normalize)} 個偏離 -14 的 MP3...'})
    total = len(need_normalize)
    done = 0

    for rel_path, val in need_normalize.items():
        abs_path = os.path.join(library_path, rel_path)
        if not os.path.exists(abs_path):
            continue
        base, ext = os.path.splitext(abs_path)
        tmp = base + '_tmp' + ext
        cmd = [ffmpeg_path, '-y', '-i', abs_path,
               '-af', f'loudnorm=I={target}:TP=-1:LRA=7',
               '-c:a', 'libmp3lame', '-q:a', '2', tmp]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=300)
            if r.returncode == 0 and os.path.exists(tmp):
                os.replace(tmp, abs_path)
                cache[rel_path] = target
                emit_json({'type': 'log', 'message': f'  ✅ {rel_path}  ({val:.1f} → -14)'})
            else:
                emit_json({'type': 'log', 'message': f'  ❌ {rel_path} normalize 失敗'})
        except Exception as e:
            emit_json({'type': 'log', 'message': f'  ⚠️ {rel_path}: {str(e)[:60]}'})
        done += 1
        emit_json({'type': 'progress', 'percent': round(done / total * 100, 1)})

    with open(cache_file, 'w', encoding='utf-8') as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)
    emit_json({'type': 'log', 'message': f'完成: 測量 {len(need_measure)} 個, normalize {done} 個'})


def _content_type(fpath):
    """Map file extension to a MIME type. Must match the actual bytes
    sent, otherwise Groq returns HTTP 502 service_unavailable."""
    ext = os.path.splitext(fpath)[1].lower()
    return {
        '.flac': 'audio/flac',
        '.mp3': 'audio/mpeg',
        '.wav': 'audio/wav',
        '.ogg': 'audio/ogg',
        '.m4a': 'audio/mp4',
        '.mp4': 'audio/mp4',
    }.get(ext, 'audio/flac')


def _clean_query(text):
    """Clean search query: remove special chars that break YouTube search."""
    text = text.replace('_', ' ').replace('\u3010', '').replace('\u3011', '').replace('\uff5c', ' ')
    text = text.replace('\uff08', ' ').replace('\uff09', ' ').replace('\u300a', '').replace('\u300b', '')
    text = text.replace('[', ' ').replace(']', ' ').replace('"', '').replace('\'', '').replace('?', '')
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def _pick_best_video(unique, podcast_name, youtube_dl):
    """Validate candidate video IDs against the podcast name.
    Returns (video_id, match_source) where match_source is 'title', 'fallback', or None.
    """
    import yt_dlp as _yt

    def _normalize(text):
        """Lowercase and strip common noise for comparison."""
        text = text.lower()
        for ch in ('【', '】', '[', ']', '（', '）', '(', ')', '|', '-', '—', '·', '│'):
            text = text.replace(ch, ' ')
        return re.sub(r'\s+', ' ', text).strip()

    podcast_norm = _normalize(podcast_name)
    # Extract meaningful keywords from podcast name (skip very short tokens)
    podcast_kw = [w for w in podcast_norm.split() if len(w) >= 2]

    # Check up to 5 candidates (enough to find the right one without being slow)
    for vid in unique[:5]:
        try:
            info_opts = {
                'quiet': True,
                'no_warnings': True,
                'skip_download': True,
                'extract_flat': False,
            }
            with _yt.YoutubeDL(info_opts) as ydl:
                info = ydl.extract_info(f'https://www.youtube.com/watch?v={vid}', download=False)
            title = info.get('title', '') or ''
            channel = info.get('channel', '') or info.get('uploader', '') or ''
            title_norm = _normalize(title)
            channel_norm = _normalize(channel)

            # Check if podcast name keywords appear in the video title or channel
            for kw in podcast_kw:
                if kw in title_norm or kw in channel_norm:
                    return vid, 'title'
        except Exception:
            continue

    # Fallback: return first candidate (original behavior)
    return unique[0], 'fallback'


def cmd_youtube_subs(args):
    """Search YouTube and download Chinese subtitles for a podcast episode"""
    query = _clean_query(args[0])
    output_path = args[1] if len(args) > 1 else ''
    podcast_name = args[2] if len(args) > 2 else ''
    if not output_path:
        emit_json({'type': 'error', 'message': 'No output path'})
        return

    import yt_dlp
    import urllib.parse
    import requests
    import re
    import shutil

    youtube_dl = shutil.which('yt-dlp') or 'yt-dlp'

    # Step 1: Search YouTube
    emit_json({'type': 'log', 'message': f'🔍 搜尋 YouTube: {query}'})
    try:
        search_url = 'https://www.youtube.com/results?' + urllib.parse.urlencode({'search_query': query})
        r = requests.get(search_url, timeout=15, headers={
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        })
        vids = re.findall(r'watch\?v=([a-zA-Z0-9_-]{11})', r.text)
        unique = list(dict.fromkeys(vids))
        if not unique:
            emit_json({'type': 'not_found', 'message': '找不到符合的 YouTube 影片'})
            return
        # Validate: prefer a video whose title/channel matches the podcast name
        if podcast_name:
            video_id, match_src = _pick_best_video(unique, podcast_name, youtube_dl)
            if match_src == 'title':
                emit_json({'type': 'log', 'message': f'  ✅ 找到影片 (匹配 podcast): https://youtube.com/watch?v={video_id}'})
            else:
                emit_json({'type': 'log', 'message': f'  ⚠️ 未找到匹配 podcast 的影片，使用第一個結果: https://youtube.com/watch?v={video_id}'})
        else:
            video_id = unique[0]
            emit_json({'type': 'log', 'message': f'  ✅ 找到影片: https://youtube.com/watch?v={video_id}'})
    except Exception as e:
        emit_json({'type': 'error', 'message': f'搜尋失敗: {e}'})
        return

    # Step 2: Download subtitles (with retry for 429)
    srt_dir = os.path.dirname(output_path) or '.'
    os.makedirs(srt_dir, exist_ok=True)
    # Replace only the final extension. String-wide .replace('.wav', '')
    # would also strip '.wav' from the podcast folder name (e.g.
    # "科技浪 Tech.wav") and save the SRT into a wrong directory.
    srt_path = os.path.splitext(output_path)[0] + '.srt'

    # Cookie：環境變數 → 桌面/文件 yt_cookies.txt → APPDATA。
    # 舊寫死作者本機中文路徑，別台機器永遠走不到。
    def _find_cookies():
        env = os.environ.get('YT_COOKIES', '')
        if env and os.path.exists(env):
            return env
        home = os.path.expanduser('~')
        for c in (os.path.join(home, 'Desktop', 'yt_cookies.txt'),
                  os.path.join(home, 'Documents', 'yt_cookies.txt'),
                  os.path.join(os.environ.get('APPDATA', ''), 'playlist-admin', 'yt_cookies.txt')):
            if c and os.path.exists(c):
                return c
        return ''
    cookie_file = _find_cookies()

    max_retries = 3
    for attempt in range(max_retries):
      try:
        ydl_opts = {
            'quiet': True,
            'no_warnings': True,
            'skip_download': True,
            'writesubtitles': True,
            'writeautomaticsub': True,
            'subtitleslangs': ['zh-TW', 'zh-Hant', 'zh', 'zh-Hans', 'en'],
            'subtitlesformat': 'srt',
            'outtmpl': os.path.splitext(srt_path)[0] + '.%(ext)s',
            'windowsfilenames': True,
            'sleep_interval_requests': 3,
            'extractor_args': {'youtube': {'sleep_interval': ['3']}},
        }
        if cookie_file:
            ydl_opts['cookiefile'] = cookie_file
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([f'https://www.youtube.com/watch?v={video_id}'])

        # Find the actual SRT file (yt-dlp may add language suffix:
        # <base>.<lang>.srt). 精確後綴比對：startswith(base) 會讓 ep1 誤抓
        # ep10.srt 並 rename 蓋掉別人的檔。
        srt_dir = os.path.dirname(srt_path) or '.'
        srt_name = os.path.basename(srt_path)
        srt_base = os.path.splitext(srt_name)[0]
        candidates = []
        for f in os.listdir(srt_dir):
            if f == srt_name or (f.startswith(srt_base + '.') and f.endswith('.srt')):
                candidates.append(os.path.join(srt_dir, f))

        srt_found = None
        for c in candidates:
            if c.endswith('.srt'):
                srt_found = c
                break

        if srt_found and os.path.exists(srt_found):
            # Rename to clean name
            if srt_found != srt_path:
                os.replace(srt_found, srt_path)
            emit_json({'type': 'log', 'message': f'  ✅ 字幕已儲存: {srt_path}'})
            emit_json({'type': 'complete', 'path': srt_path})
            return
        else:
            emit_json({'type': 'not_found', 'message': '下載字幕失敗（無可用字幕）'})
            return
      except Exception as e:
        err_str = str(e)
        if '429' in err_str or 'Too Many Requests' in err_str:
            if attempt < max_retries - 1:
                wait = 10 * (attempt + 1)
                emit_json({'type': 'log', 'message': f'  ⚠️ YouTube 限流，等 {wait} 秒後重試 ({attempt+1}/{max_retries})...'})
                time.sleep(wait)
                continue
        emit_json({'type': 'error', 'message': f'下載字幕異常: {e}'})
        return


def _rag_script(name):
    """Locate a rag script next to this bridge (assets/tools/rag in release,
    repo rag/ in dev / CLI), or relative to cwd."""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        os.path.join(here, 'rag', name),                      # temp extracted / bundle copy
        os.path.join(here, '..', 'rag', name),                # repo: tools/../rag
        os.path.join(os.getcwd(), 'rag', name),               # CLI: cwd = repo root
        os.path.join(os.getcwd(), '..', 'rag', name),
        os.path.join(os.getcwd(), '..', '..', 'rag', name),
        os.environ.get('PA_ROOT', '') and os.path.join(os.environ['PA_ROOT'], 'rag', name),
    ]
    for c in cands:
        if c and os.path.exists(c):
            return c
    return ''


def cmd_rag_query(args):
    """Query the podcast RAG: python rag/query.py "<q>" --answer --json --out <tmp>"""
    script = _rag_script('query.py')
    if not script:
        emit_json({'type': 'error', 'message': '找不到 rag/query.py（release 需打包 assets/tools/rag）'})
        return
    question = args[0]
    topk = args[1] if len(args) > 1 else '8'
    show = args[2] if len(args) > 2 else ''
    out_file = os.path.join(tempfile.gettempdir(), f'pa_rag_{int(time.time() * 1000)}.json')
    cmd = [sys.executable, script, question, '--no-full', '--topk', str(topk), '--answer', '--json', '--out', out_file]
    if show:
        cmd += ['--show', show]
    env = dict(os.environ)
    env['BASE_PATH'] = env.get('BASE_PATH', '')
    try:
        r = subprocess.run(cmd, capture_output=True, encoding='utf-8', errors='replace',
                           env=env, timeout=900, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if not os.path.exists(out_file):
            emit_json({'type': 'error', 'message': (r.stderr or r.stdout or '無輸出').strip()[-500:]})
            return
        with open(out_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
        os.unlink(out_file)
    except Exception as e:
        emit_json({'type': 'error', 'message': f'rag-query 執行失敗: {e}'})
        return
    emit_json({'type': 'rag_result', 'data': data})


def cmd_rag_build(args):
    """Incremental RAG build: python rag/build_db.py"""
    script = _rag_script('build_db.py')
    if not script:
        emit_json({'type': 'error', 'message': '找不到 rag/build_db.py（release 需打包 assets/tools/rag）'})
        return
    cmd = [sys.executable, script]
    if '--reset' in args:
        cmd.append('--reset')
    env = dict(os.environ)
    env['BASE_PATH'] = env.get('BASE_PATH', '')
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                encoding='utf-8', errors='replace', env=env,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                line = line.strip()
                if line:
                    emit_json({'type': 'log', 'message': line})
            proc.wait(timeout=3600)
        except subprocess.TimeoutExpired:
            # 超時只報錯不 kill 會留孤兒行程續佔 ChromaDB 鎖。
            try:
                proc.kill()
            except Exception:
                pass
            emit_json({'type': 'error', 'message': 'rag-build 逾時已終止 (3600s)'})
            return
        emit_json({'type': 'complete', 'message': 'RAG 索引更新完成'})
    except Exception as e:
        emit_json({'type': 'error', 'message': f'rag-build 執行失敗: {e}'})


def main():
    if len(sys.argv) < 2:
        emit_json({'type': 'error', 'message': 'No command specified'})
        return 1

    command = sys.argv[1]
    args = sys.argv[2:]

    try:
        if command == 'rss-list':
            cmd_rss_list(args)
        elif command == 'rss-get-audio':
            cmd_rss_get_audio(args)
        elif command == 'rss-download':
            cmd_rss_download(args)
        elif command == 'download-song':
            cmd_download_song(args)
        elif command == 'download-youtube':
            cmd_download_youtube(args)
        elif command == 'download-spotdl':
            cmd_download_spotdl(args)
        elif command == 'groq-transcribe':
            # legacy：已由 groq_native_service.dart 取代，保留命令名避免舊呼叫炸掉
            emit_json({'type': 'error', 'message': 'groq-transcribe retired, use native Groq'})
        elif command == 'list-missing':
            cmd_list_missing(args)
        elif command == 'batch-download':
            cmd_batch_download(args)
        elif command == 'normalize-mp3-lufs':
            cmd_normalize_mp3_lufs(args)
        elif command == 'youtube-subs':
            cmd_youtube_subs(args)
        elif command == 'rag-query':
            cmd_rag_query(args)
        elif command == 'rag-build':
            cmd_rag_build(args)
        else:
            emit_json({'type': 'error', 'message': f'Unknown command: {command}'})
            return 1
    except Exception as e:
        emit_json({'type': 'error', 'message': str(e), 'traceback': traceback.format_exc()})
        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main())
